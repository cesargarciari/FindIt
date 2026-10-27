import Foundation
import Synchronization
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

    @Test func describeTurnsThinkingOffByDefault() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"message":{"role":"assistant","content":"{}"}}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        _ = try await client.describe(imageJPEG: Data([1]), prompt: "p", schemaJSON: "{}", model: "m")

        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(try json(request.body)["think"] as? Bool == false)
    }

    @Test func describeOmitsThinkWhenNil() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"message":{"role":"assistant","content":"{}"}}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        _ = try await client.describe(imageJPEG: Data([1]), prompt: "p", schemaJSON: "{}", model: "m", think: nil)

        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(try json(request.body)["think"] == nil)
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

    @Test func isInstalledAcceptsTheLatestTag() {
        let installed = ["qwen3-vl:8b", "bge-m3:latest"]

        #expect(OllamaClient.isInstalled("qwen3-vl:8b", in: installed))
        #expect(OllamaClient.isInstalled("bge-m3", in: installed))
        #expect(OllamaClient.isInstalled("bge-m3:latest", in: installed))
        #expect(!OllamaClient.isInstalled("qwen3-vl", in: installed))
        #expect(!OllamaClient.isInstalled("nomic-embed-text", in: installed))
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

    @Test func timeoutIsSeparateFromUnreachable() async {
        let (session, baseURL) = MockURLProtocol.stub(error: .timedOut)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.installedModels()
        } throws: { error in
            if case OllamaError.timedOut = error { true } else { false }
        }
    }

    // URLSession also reports .cancelled when the session itself is invalidated. With the task
    // still running, that's an ordinary failure, so the screenshot gets marked failed.
    @Test func cancelledRequestWithoutTaskCancelIsUnreachable() async {
        let (session, baseURL) = MockURLProtocol.stub(error: .cancelled)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.installedModels()
        } throws: { error in
            if case OllamaError.unreachable(let urlError) = error { urlError.code == .cancelled } else { false }
        }
    }

    // MainActor keeps the task from starting until `pending` holds it, so onStart can always cancel it.
    @MainActor @Test func cancelledRequestFromCancelledTaskIsCancellationError() async {
        let pending = Mutex<Task<[String], any Error>?>(nil)
        let (session, baseURL) = MockURLProtocol.stub(error: .cancelled) {
            pending.withLock { $0?.cancel() }
        }
        let client = OllamaClient(baseURL: baseURL, session: session)

        let task = Task { @MainActor in try await client.installedModels() }
        pending.withLock { $0 = task }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
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

    @Test func errorStatusKeepsOnlyOllamaErrorField() async {
        let (session, baseURL) = MockURLProtocol.stub(status: 500, body: #"{"error":"out of memory","detail":"ignored"}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.installedModels()
        } throws: { error in
            if case OllamaError.badStatus(500, let body) = error { body == "out of memory" } else { false }
        }
    }

    @Test(arguments: [
        #"{"error":"\#(String(repeating: "x", count: 2000))"}"#,
        "<html>\(String(repeating: "proxy error ", count: 1000))</html>",
    ])
    func errorStatusBodyIsCappedAt512Characters(responseBody: String) async {
        let (session, baseURL) = MockURLProtocol.stub(status: 502, body: responseBody)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await client.installedModels()
        } throws: { error in
            if case OllamaError.badStatus(_, let body) = error { body.count == 512 } else { false }
        }
    }

    // MainActor keeps the task from starting until `pending` holds it, so onStart can always cancel it.
    @MainActor @Test func cancellationWhileRequestIsInFlightThrowsCancellationError() async {
        let pending = Mutex<Task<[String], any Error>?>(nil)
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"models":[]}"#) {
            pending.withLock { $0?.cancel() }
        }
        let client = OllamaClient(baseURL: baseURL, session: session)

        let task = Task { @MainActor in try await client.installedModels() }
        pending.withLock { $0 = task }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
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

    private func collect(_ stream: AsyncThrowingStream<PullProgress, any Error>) async throws -> [PullProgress] {
        var updates: [PullProgress] = []
        for try await update in stream { updates.append(update) }
        return updates
    }

    @Test func pullStreamsProgressUntilSuccess() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: """
            {"status":"pulling manifest"}
            {"status":"pulling 6a0746a1ec1a","digest":"sha256:6a07","total":200,"completed":50}
            {"status":"success"}

            """)
        let client = OllamaClient(baseURL: baseURL, session: session)

        let updates = try await collect(client.pull("bge-m3"))

        #expect(updates == [
            PullProgress(status: "pulling manifest", completed: nil, total: nil),
            PullProgress(status: "pulling 6a0746a1ec1a", completed: 50, total: 200),
            PullProgress(status: "success", completed: nil, total: nil),
        ])
        #expect(updates[1].fraction == 0.25)
        #expect(updates[0].fraction == nil)
        let request = try #require(MockURLProtocol.captured(for: baseURL).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/pull")
        #expect(try json(request.body)["model"] as? String == "bge-m3")
    }

    @Test func pullThrowsOllamasErrorLine() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: """
            {"status":"pulling manifest"}
            {"error":"pull model manifest: file does not exist"}
            """)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await collect(client.pull("no-such-model"))
        } throws: { error in
            if case OllamaError.pullFailed("pull model manifest: file does not exist") = error { true } else { false }
        }
    }

    @Test func pullThatEndsWithoutSuccessThrows() async throws {
        let (session, baseURL) = MockURLProtocol.stub(body: #"{"status":"pulling manifest"}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await collect(client.pull("bge-m3"))
        } throws: { error in
            if case OllamaError.pullFailed = error { true } else { false }
        }
    }

    @Test func pullBadStatusCarriesOllamasMessage() async throws {
        let (session, baseURL) = MockURLProtocol.stub(status: 500, body: #"{"error":"disk full"}"#)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await collect(client.pull("bge-m3"))
        } throws: { error in
            if case OllamaError.badStatus(500, "disk full") = error { true } else { false }
        }
    }

    @Test func pullWhenOllamaIsDownIsUnreachable() async throws {
        let (session, baseURL) = MockURLProtocol.stub(error: .cannotConnectToHost)
        let client = OllamaClient(baseURL: baseURL, session: session)

        await #expect {
            _ = try await collect(client.pull("bge-m3"))
        } throws: { error in
            if case OllamaError.unreachable = error { true } else { false }
        }
    }

    @Test func fractionIsCappedAtOne() {
        #expect(PullProgress(status: "x", completed: 300, total: 200).fraction == 1)
        #expect(PullProgress(status: "x", completed: 5, total: 0).fraction == nil)
    }
}
