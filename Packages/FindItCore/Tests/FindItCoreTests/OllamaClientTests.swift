import Foundation
import Testing
@testable import FindItCore

struct OllamaClientTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func defaultBaseURLIsLocalOllama() {
        #expect(OllamaClient().baseURL.absoluteString == "http://localhost:11434")
    }

    @Test func embedSendsModelAndInputAndDecodesVectors() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"model":"bge-m3","embeddings":[[0.1,0.2],[0.3,0.4]]}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        let vectors = try await client.embed(["hola", "hello"], model: "bge-m3")

        #expect(vectors == [[0.1, 0.2], [0.3, 0.4]])
        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/embed")
        #expect(request.timeout == 60)
        let body = try json(request.body)
        #expect(body["model"] as? String == "bge-m3")
        #expect(body["input"] as? [String] == ["hola", "hello"])
    }

    @Test func embedWithNoTextsSkipsTheServer() async throws {
        let (session, baseURL) = MockURLProtocol.stub()
        let client = OllamaClient(baseURL: baseURL, session: session)

        #expect(try await client.embed([], model: "bge-m3").isEmpty)
        #expect(MockURLProtocol.captured(for: baseURL).isEmpty)
    }

    @Test func embedFailsWhenVectorCountDoesNotMatch() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"embeddings":[[0.1]]}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.embed(["a", "b"], model: "bge-m3")
        } throws: { error in
            if case OllamaError.decodingFailed = error { true } else { false }
        }
    }

    @Test func describeSendsImagePromptAndSchema() async throws {
        let reply = #"{"description":"A receipt","category":"receipt"}"#
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "model": "qwen3-vl:8b",
            "message": ["role": "assistant", "content": reply],
            "done": true,
        ])
        let (session, baseURL) = MockURLProtocol.stub(body: String(decoding: responseBody, as: UTF8.self))
        let client = OllamaClient(baseURL: baseURL, session: session)
        let image = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])

        let content = try await client.describe(
            imageJPEG: image,
            prompt: "Describe this screenshot.",
            schemaJSON: #"{"type":"object","properties":{"description":{"type":"string"}}}"#,
            model: "qwen3-vl:8b",
            temperature: 0
        )

        #expect(content == reply)
        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/chat")
        #expect(request.timeout == 180)

        let body = try json(request.body)
        #expect(body["model"] as? String == "qwen3-vl:8b")
        #expect(body["stream"] as? Bool == false)
        // The schema must arrive as a JSON object, not as a string.
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["type"] as? String == "object")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Describe this screenshot.")
        #expect(messages[0]["images"] as? [String] == [image.base64EncodedString()])
    }

    @Test func describeOmitsOptionsWithoutTemperature() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"message":{"role":"assistant","content":"{}"}}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        _ = try await client.describe(imageJPEG: Data([1]), prompt: "p", schemaJSON: "{}", model: "m")

        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(try json(request.body)["options"] == nil)
    }

    @Test func describeRejectsInvalidSchemaWithoutCallingServer() async throws {
        let (session, baseURL) = MockURLProtocol.stub()
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.describe(imageJPEG: Data([1]), prompt: "p", schemaJSON: "not json", model: "m")
        } throws: { error in
            if case OllamaError.invalidSchema = error { true } else { false }
        }
        #expect(MockURLProtocol.captured(for: baseURL).isEmpty)
    }

    @Test func installedModelsDecodesTags() async throws {
        let (session, baseURL) = MockURLProtocol.stub(
            body: #"{"models":[{"name":"qwen3-vl:8b","size":1},{"name":"bge-m3:latest","size":2}]}"#
        )
        let client = OllamaClient(baseURL: baseURL, session: session)

        #expect(try await client.installedModels() == ["qwen3-vl:8b", "bge-m3:latest"])
        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/tags")
        #expect(request.timeout == 60)
    }

    @Test func isAvailableReflectsTagsResponse() async {
        let (upSession, upURL) = MockURLProtocol.stub(body: #"{"models":[]}"#)
        let (downSession, downURL) = MockURLProtocol.stub(error: .cannotConnectToHost)

        #expect(await OllamaClient(baseURL: upURL, session: upSession).isAvailable())
        #expect(await !OllamaClient(baseURL: downURL, session: downSession).isAvailable())
    }

    @Test func connectionFailureIsUnreachable() async {
        let (session, baseURL) = MockURLProtocol.stub(error: .cannotConnectToHost)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.installedModels()
        } throws: { error in
            if case OllamaError.unreachable(let urlError) = error {
                urlError.code == .cannotConnectToHost
            } else {
                false
            }
        }
    }

    @Test func cancellationIsNotReportedAsUnreachable() async {
        let (session, baseURL) = MockURLProtocol.stub(error: .cancelled)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect(throws: CancellationError.self) {
            _ = try await client.installedModels()
        }
    }

    @Test func errorStatusIncludesCodeAndBody() async {
        let (session, baseURL) = MockURLProtocol.stub(status: 404, body: #"{"error":"model 'x' not found"}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.embed(["a"], model: "x")
        } throws: { error in
            if case OllamaError.badStatus(let code, let body) = error {
                code == 404 && body.contains("not found")
            } else {
                false
            }
        }
    }

    @Test func malformedResponseIsDecodingFailure() async {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"unexpected":true}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.describe(imageJPEG: Data([1]), prompt: "p", schemaJSON: "{}", model: "m")
        } throws: { error in
            if case OllamaError.decodingFailed = error { true } else { false }
        }
    }
}
