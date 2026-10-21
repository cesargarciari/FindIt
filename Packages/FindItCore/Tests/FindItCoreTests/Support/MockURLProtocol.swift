import Foundation
import Synchronization

/// Answers every request with a canned response, so tests never reach a real server.
/// Each test registers its own made-up host, which keeps parallel tests apart.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let method: String
        let path: String
        let timeout: TimeInterval
        let body: Data
    }

    private struct Stub {
        var status: Int
        var body: Data
        var error: URLError.Code?
        var onStart: (@Sendable () -> Void)?
        var captured: [Captured] = []
    }

    private static let stubs = Mutex<[String: Stub]>([:])

    /// Returns a URLSession and base URL whose requests get `status` and `body` back.
    /// `onStart` runs when a request arrives, before the response is sent.
    static func stub(
        status: Int = 200,
        body: String = "",
        error: URLError.Code? = nil,
        onStart: (@Sendable () -> Void)? = nil
    ) -> (URLSession, URL) {
        let host = "\(UUID().uuidString.lowercased()).mock"
        stubs.withLock { $0[host] = Stub(status: status, body: Data(body.utf8), error: error, onStart: onStart) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return (URLSession(configuration: configuration), URL(string: "http://\(host)")!)
    }

    static func captured(for baseURL: URL) -> [Captured] {
        stubs.withLock { $0[baseURL.host() ?? ""]?.captured ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let captured = Captured(
            method: request.httpMethod ?? "",
            path: request.url?.path() ?? "",
            timeout: request.timeoutInterval,
            body: Self.readBody(of: request)
        )
        let stub = Self.stubs.withLock { stubs -> Stub? in
            stubs[host]?.captured.append(captured)
            return stubs[host]
        }

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        stub.onStart?()
        if let code = stub.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // URLSession moves httpBody into a stream before it reaches a URLProtocol.
    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
