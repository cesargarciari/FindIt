import Foundation
import Testing
@testable import FindItCore

// The queue's tests will trust these fakes, so check that the failure settings do what they say.
struct FakesTests {
    private let url = URL(fileURLWithPath: "/shot.png")

    @Test func failsOnlyTheFirstCalls() async throws {
        let ocr = FakeTextRecognizer(text: "hola", failure: .firstCalls(2))

        await #expect(throws: FakeError.self) { try await ocr.recognizeText(at: url) }
        await #expect(throws: FakeError.self) { try await ocr.recognizeText(at: url) }
        #expect(try await ocr.recognizeText(at: url) == "hola")
        #expect(ocr.callCount == 3)
    }

    @Test func alwaysFailingFakeStillCountsCalls() async {
        let describer = FakeImageDescriber(failure: .always)

        for _ in 0 ..< 3 {
            await #expect(throws: FakeError.self) {
                try await describer.describe(imageJPEG: Data(), prompt: "p", schemaJSON: "{}", model: "m")
            }
        }
        #expect(describer.callCount == 3)
    }

    @Test func countsConcurrentCalls() async throws {
        let embedder = FakeTextEmbedder(vector: [1, 0])

        try await withThrowingTaskGroup(of: [[Float]].self) { group in
            for _ in 0 ..< 50 {
                group.addTask { try await embedder.embed(["a", "b"], model: "m") }
            }
            for try await vectors in group {
                #expect(vectors == [[1, 0], [1, 0]])
            }
        }
        #expect(embedder.callCount == 50)
    }

    @Test func embedderRecordsTexts() async throws {
        let embedder = FakeTextEmbedder(failure: .firstCalls(1))

        await #expect(throws: FakeError.self) { try await embedder.embed(["a"], model: "m") }
        _ = try await embedder.embed(["b", "c"], model: "m")

        #expect(embedder.receivedTexts == [["a"], ["b", "c"]])
    }

    @Test func labelerReturnsConfiguredLabels() async throws {
        let labeler = FakeImageLabeler(labels: ["receipt"])

        #expect(try await labeler.labels(forImageAt: url) == ["receipt"])
        #expect(labeler.callCount == 1)
    }
}
