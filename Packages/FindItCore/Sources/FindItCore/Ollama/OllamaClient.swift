import Foundation

public enum OllamaError: Error, Sendable {
    /// The server could not be reached.
    case unreachable(URLError)
    /// The server didn't answer in time, often because it is still loading the model. Worth retrying.
    case timedOut
    /// `body` is Ollama's `error` message when the reply has one, otherwise the raw body, capped at 512 characters.
    case badStatus(code: Int, body: String)
    case decodingFailed(String)
    /// The schema passed to `describe` is not valid JSON.
    case invalidSchema
    /// Ollama stopped a model download, with its message, or the download ended before it finished.
    case pullFailed(String)
}

/// One progress update from `pull`.
public struct PullProgress: Equatable, Sendable {
    /// Ollama's own words, such as "pulling manifest" or "verifying sha256 digest".
    public let status: String
    /// Bytes of the part being downloaded; nil while Ollama does something else.
    public let completed: Int64?
    public let total: Int64?

    /// From 0 to 1 while a part downloads, otherwise nil.
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(Double(completed) / Double(total), 1)
    }
}

/// Talks to a local Ollama server over its HTTP API.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    // The first describe call loads the vision model into memory, which can take minutes.
    static let describeTimeout: TimeInterval = 180
    static let defaultTimeout: TimeInterval = 60
    // How long a download may go quiet; verifying a large model sends nothing for a while.
    static let pullTimeout: TimeInterval = 300
    // Named once, because the ImageDescribing conformance forwards these same defaults.
    public static let defaultTemperature: Double? = nil
    public static let defaultThink: Bool? = false
    // A proxy or HTML error page can be any size, and the body may end up in fail_reason.
    static let maxErrorBodyLength = 512

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Returns one embedding per input text, in the same order.
    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        if texts.isEmpty { return [] }
        let body = try JSONEncoder().encode(EmbedRequest(model: model, input: texts))
        let data = try await send(path: "api/embed", method: "POST", body: body, timeout: Self.defaultTimeout)
        let response = try decode(EmbedResponse.self, from: data)
        guard response.embeddings.count == texts.count else {
            throw OllamaError.decodingFailed("Expected \(texts.count) embeddings, got \(response.embeddings.count)")
        }
        return response.embeddings
    }

    /// Sends one image with a prompt and returns the model's raw `message.content`.
    ///
    /// `think` defaults to false because qwen3-vl thinks by default, which slows every call.
    /// Pass nil to leave the field out, for models that reject it.
    public func describe(
        imageJPEG: Data,
        prompt: String,
        schemaJSON: String,
        model: String,
        temperature: Double? = OllamaClient.defaultTemperature,
        think: Bool? = OllamaClient.defaultThink
    ) async throws -> String {
        // The schema is arbitrary JSON, so the body is built with JSONSerialization instead of Codable.
        guard let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) else {
            throw OllamaError.invalidSchema
        }
        var request: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                    "images": [imageJPEG.base64EncodedString()],
                ]
            ],
            "format": schema,
            "stream": false,
        ]
        if let temperature {
            request["options"] = ["temperature": temperature]
        }
        if let think {
            request["think"] = think
        }
        let body = try JSONSerialization.data(withJSONObject: request)
        let data = try await send(path: "api/chat", method: "POST", body: body, timeout: Self.describeTimeout)
        return try decode(ChatResponse.self, from: data).message.content
    }

    public func isAvailable() async -> Bool {
        (try? await installedModels()) != nil
    }

    /// Whether `model` is in an `installedModels()` list. Ollama lists "bge-m3" as "bge-m3:latest".
    public static func isInstalled(_ model: String, in installed: [String]) -> Bool {
        installed.contains(model) || installed.contains(model + ":latest")
    }

    public func installedModels() async throws -> [String] {
        let data = try await send(path: "api/tags", method: "GET", body: nil, timeout: Self.defaultTimeout)
        return try decode(TagsResponse.self, from: data).models.map(\.name)
    }

    /// Downloads `model` into Ollama, yielding each progress update Ollama streams.
    /// The stream finishes once Ollama reports success. Stopping iteration cancels the download request.
    public func pull(_ model: String) -> AsyncThrowingStream<PullProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamPull(model) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamPull(_ model: String, onProgress: (PullProgress) -> Void) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/pull"), timeoutInterval: Self.pullTimeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(PullRequest(model: model, stream: true))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw Self.transportError(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = Data()
            for try await byte in bytes.prefix(Self.maxErrorBodyLength) { body.append(byte) }
            throw OllamaError.badStatus(code: status, body: Self.errorMessage(from: body))
        }

        // Ollama streams one JSON object per line.
        for try await line in bytes.lines {
            let update = try decode(PullLine.self, from: Data(line.utf8))
            if let error = update.error {
                throw OllamaError.pullFailed(String(error.prefix(Self.maxErrorBodyLength)))
            }
            let progress = PullProgress(status: update.status ?? "", completed: update.completed, total: update.total)
            onProgress(progress)
            if progress.status == "success" { return }
        }
        try Task.checkCancellation()
        throw OllamaError.pullFailed("The download ended before Ollama reported success.")
    }

    private func send(path: String, method: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.transportError(error)
        }
        // A cancel that lands after the response arrived would otherwise still be processed.
        try Task.checkCancellation()

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OllamaError.badStatus(code: status, body: Self.errorMessage(from: data))
        }
        return data
    }

    private static func transportError(_ error: URLError) -> any Error {
        // A cancelled task (app quit, indexing stopped) must not mark a screenshot as failed.
        // .cancelled alone isn't enough: an invalidated session reports it too, and that is a real failure.
        if error.code == .cancelled && Task.isCancelled { return CancellationError() }
        if error.code == .timedOut { return OllamaError.timedOut }
        return OllamaError.unreachable(error)
    }

    private static func errorMessage(from data: Data) -> String {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            ?? String(decoding: data, as: UTF8.self)
        return String(message.prefix(maxErrorBodyLength))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OllamaError.decodingFailed(String(describing: error))
        }
    }
}

private struct EmbedRequest: Encodable {
    let model: String
    let input: [String]
}

private struct EmbedResponse: Decodable {
    let embeddings: [[Float]]
}

private struct PullRequest: Encodable {
    let model: String
    let stream: Bool
}

private struct PullLine: Decodable {
    let status: String?
    let completed: Int64?
    let total: Int64?
    let error: String?
}

private struct ChatResponse: Decodable {
    struct Message: Decodable {
        let content: String
    }
    let message: Message
}

private struct ErrorResponse: Decodable {
    let error: String
}

private struct TagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }
    let models: [Model]
}
