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
}

/// Talks to a local Ollama server over its HTTP API.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    // The first describe call loads the vision model into memory, which can take minutes.
    static let describeTimeout: TimeInterval = 180
    static let defaultTimeout: TimeInterval = 60
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

    public func installedModels() async throws -> [String] {
        let data = try await send(path: "api/tags", method: "GET", body: nil, timeout: Self.defaultTimeout)
        return try decode(TagsResponse.self, from: data).models.map(\.name)
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
            // A cancelled task (app quit, indexing stopped) must not mark a screenshot as failed.
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw OllamaError.timedOut }
            throw OllamaError.unreachable(error)
        }
        // A cancel that lands after the response arrived would otherwise still be processed.
        try Task.checkCancellation()

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OllamaError.badStatus(code: status, body: Self.errorMessage(from: data))
        }
        return data
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
