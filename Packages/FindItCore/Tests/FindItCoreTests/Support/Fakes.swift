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

/// Holds every recognizeText call at a gate until the test calls `release()`, so a test can act
/// while run() is suspended in the middle of a step. A cancel, such as a test's time limit,
/// releases waiting calls with CancellationError, so a broken test fails instead of hanging.
final class GatedTextRecognizer: TextRecognizing {
    private struct State {
        var isOpen = false
        var isCancelled = false
        var waiting: [CheckedContinuation<Void, any Error>] = []
        var calls = 0
    }

    let text: String
    private let state = Mutex(State())
    // Buffered, so a call that arrives before the test starts waiting isn't missed.
    private let arrivals: AsyncStream<Void>
    private let arrivalSignal: AsyncStream<Void>.Continuation

    init(text: String = "Hola FindIt") {
        self.text = text
        (arrivals, arrivalSignal) = AsyncStream.makeStream()
    }

    var callCount: Int {
        state.withLock { $0.calls }
    }

    func recognizeText(at url: URL) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (isOpen, isCancelled) = state.withLock { state in
                    state.calls += 1
                    if !state.isOpen && !state.isCancelled {
                        state.waiting.append(continuation)
                    }
                    return (state.isOpen, state.isCancelled)
                }
                if isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isOpen {
                    continuation.resume()
                } else {
                    arrivalSignal.yield()
                }
            }
        } onCancel: {
            // Also runs straight away if the task was already cancelled, hence the flag.
            let waiting = state.withLock { state in
                state.isCancelled = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting {
                continuation.resume(throwing: CancellationError())
            }
        }
        return text
    }

    /// Returns once a call is waiting at the closed gate.
    func waitForWaitingCall() async {
        for await _ in arrivals {
            return
        }
    }

    /// Opens the gate for good: the waiting calls continue, and later calls don't stop.
    func release() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
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
    private let received = Mutex<[[String]]>([])

    init(vector: [Float] = [0.6, 0.8], failure: FakeFailure = .never) {
        self.vector = vector
        self.calls = FakeCalls(failure: failure)
    }

    var callCount: Int { calls.count }

    /// The texts of every call in order, including calls that failed.
    var receivedTexts: [[String]] {
        received.withLock { $0 }
    }

    /// Returns `vector` once per input text, like the real embedder returns one per text.
    func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        received.withLock { $0.append(texts) }
        try calls.record()
        return texts.map { _ in vector }
    }
}
