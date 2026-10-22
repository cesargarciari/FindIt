import Foundation
import Synchronization
@testable import FindItCore

struct FakeError: Error, Equatable {}

/// When a fake throws `FakeError` instead of returning its result.
enum FakeFailure: Sendable {
    case never
    case firstCalls(Int)
    case always
}

/// Shared by the fakes: counts calls and decides whether each one fails.
/// A Mutex keeps the count correct when the queue calls from several tasks.
final class FakeCalls: Sendable {
    let failure: FakeFailure
    private let calls = Mutex(0)

    init(failure: FakeFailure) {
        self.failure = failure
    }

    var count: Int {
        calls.withLock { $0 }
    }

    /// Records one call, then throws if this call should fail.
    func record() throws {
        let callNumber = calls.withLock { count in
            count += 1
            return count
        }
        switch failure {
        case .never: return
        case .firstCalls(let n): if callNumber <= n { throw FakeError() }
        case .always: throw FakeError()
        }
    }
}

final class FakeTextRecognizer: TextRecognizing {
    let text: String
    let calls: FakeCalls

    init(text: String = "Hola FindIt", failure: FakeFailure = .never) {
        self.text = text
        self.calls = FakeCalls(failure: failure)
    }

    var callCount: Int { calls.count }

    func recognizeText(at url: URL) async throws -> String {
        try calls.record()
        return text
    }
}

final class FakeImageLabeler: ImageLabeling {
    let labels: [String]
    let calls: FakeCalls

    init(labels: [String] = ["document"], failure: FakeFailure = .never) {
        self.labels = labels
        self.calls = FakeCalls(failure: failure)
    }

    var callCount: Int { calls.count }

    func labels(forImageAt url: URL) async throws -> [String] {
        try calls.record()
        return labels
    }
}

final class FakeImageDescriber: ImageDescribing {
    let response: String
    let calls: FakeCalls

    init(
        response: String = #"{"description":"A receipt","category":"document","language":"en","entities":[]}"#,
        failure: FakeFailure = .never
    ) {
        self.response = response
        self.calls = FakeCalls(failure: failure)
    }

    var callCount: Int { calls.count }

    func describe(imageJPEG: Data, prompt: String, schemaJSON: String, model: String) async throws -> String {
        try calls.record()
        return response
    }
}

final class FakeTextEmbedder: TextEmbedding {
    let vector: [Float]
    let calls: FakeCalls

    init(vector: [Float] = [0.6, 0.8], failure: FakeFailure = .never) {
        self.vector = vector
        self.calls = FakeCalls(failure: failure)
    }

    var callCount: Int { calls.count }

    /// Returns `vector` once per input text, like the real embedder returns one per text.
    func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        try calls.record()
        return texts.map { _ in vector }
    }
}
