import Foundation
import GRDB

/// Errors the queue raises itself, rather than ones from a step's service.
public enum IndexQueueError: Error, Equatable, Sendable {
    /// No vector, or an empty one; stored, it would trap dot() in search.
    case emptyEmbedding
    /// A step failed and saving that failure failed too, so run() stopped instead of retrying it forever.
    /// `reason` is the database error, so the caller can say why indexing stopped.
    case cannotRecordFailure(Int64, reason: String)
}

/// What enqueue did with the files it was given.
public struct EnqueueResult: Equatable, Sendable {
    /// New screenshots saved as pending. A file whose hash is already stored isn't counted.
    public let added: Int
    /// Paths of files that couldn't be read, so they were left out.
    public let skipped: [String]
}

public actor IndexQueue {
    private let store: ScreenshotStore
    private let recognizer: any TextRecognizing
    private let describer: any ImageDescribing
    private let labeler: any ImageLabeling
    private let embedder: any TextEmbedding
    private let config: IndexConfig
    private let hasher = FileHasher()
    private let resizer = ImageResizer()
    private var isRunning = false
    /// Someone asked for more work while run() was busy, so it must look again before it stops.
    private var moreWorkRequested = false

    public init(
        db: DatabaseQueue,
        recognizer: any TextRecognizing,
        describer: any ImageDescribing,
        labeler: any ImageLabeling,
        embedder: any TextEmbedding,
        config: IndexConfig = IndexConfig()
    ) {
        self.store = ScreenshotStore(db)
        self.recognizer = recognizer
        self.describer = describer
        self.labeler = labeler
        self.embedder = embedder
        self.config = config
    }

    /// Adds new images as pending. One unreadable file is skipped rather than stopping the rest;
    /// only a database error is thrown.
    public func enqueue(_ urls: [URL]) async throws -> EnqueueResult {
        var added = 0
        var skipped: [String] = []
        for url in urls {
            let hash: String
            do {
                hash = try hasher.sha256(of: url)
            } catch {
                skipped.append(url.path)
                continue
            }
            if try await store.insertPending(path: url.path, fileHash: hash) != nil {
                added += 1
                moreWorkRequested = true
            }
        }
        return EnqueueResult(added: added, skipped: skipped)
    }

    /// Processes screenshots until none are unfinished, or until cancelled.
    /// A cancel returns quietly. A database error, or a failure that couldn't be saved, is thrown.
    ///
    /// Only one run works at a time: a second call during a run returns at once, and the running
    /// loop picks up its work instead. So don't treat a return as "everything is indexed", and call
    /// run() after every enqueue, so new screenshots are picked up even if no run is going.
    public func run() async throws {
        guard !isRunning else {
            moreWorkRequested = true
            return
        }
        isRunning = true
        defer { isRunning = false }

        // Screenshot ids whose failure couldn't be saved, with the database error.
        var couldNotSaveFailure: [Int64: String] = [:]
        do {
            while !Task.isCancelled {
                guard let shot = try await store.nextUnfinished(), let id = shot.id else {
                    // Work added while that read ran may be missing from its result, so look once more.
                    if moreWorkRequested {
                        moreWorkRequested = false
                        continue
                    }
                    return
                }
                // nextUnfinished returns the lowest id, so a shot whose failure couldn't be saved would come back forever.
                if let reason = couldNotSaveFailure[id] {
                    throw IndexQueueError.cannotRecordFailure(id, reason: reason)
                }
                do {
                    try await process(shot)
                } catch is CancellationError where Task.isCancelled {
                    return
                } catch {
                    couldNotSaveFailure[id] = String(describing: error)
                }
            }
        } catch is CancellationError where Task.isCancelled {
            // GRDB throws this when a cancel lands during the read. Stopping isn't an error.
        }
    }

    /// Runs one step for one screenshot. A step's error is saved as a failure.
    /// Throws only on cancellation, or if saving the failure itself fails.
    private func process(_ shot: Screenshot) async throws {
        guard let id = shot.id else { return }
        let url = URL(fileURLWithPath: shot.path)
        do {
            switch shot.status {
            case .pending:
                let text = try await withRetry { try await recognizer.recognizeText(at: url) }
                try await store.saveOCR(id: id, text: text)
            case .ocrDone:
                // Reading a local file isn't flaky, so only the model call is retried.
                let jpeg = try resizer.jpegData(forImageAt: url, maxDimension: config.maxDimension)
                let result = try await withRetry {
                    let raw = try await describer.describe(
                        imageJPEG: jpeg,
                        prompt: describePrompt,
                        schemaJSON: describeSchemaJSON,
                        model: config.describerModel
                    )
                    // Decoded inside the retry, so malformed JSON asks the model again
                    // instead of re-decoding the same bad text.
                    return try decodeDescription(raw)
                }
                try await store.saveDescription(id: id, result: result, model: config.describerModel)
            case .described:
                let ocr = shot.ocrText ?? ""
                let labels = try await optionalLabels(forImageAt: url, ocr: ocr)
                let text = searchableText(ocr: ocr, description: shot.description ?? "", labels: labels)
                let vector = try await withRetry {
                    let vectors = try await embedder.embed([documentPrefix(for: config.embedderModel) + text], model: config.embedderModel)
                    guard let first = vectors.first, !first.isEmpty else { throw IndexQueueError.emptyEmbedding }
                    return first
                }
                // The prefix only helps the embedding model; in keyword search it would be noise.
                try await store.saveIndexed(
                    id: id,
                    labels: labels,
                    searchableText: text,
                    vector: normalize(vector),
                    model: config.embedderModel
                )
            case .indexed, .failed:
                return
            }
        } catch is CancellationError where Task.isCancelled {
            // Only a real cancel stops the queue. A step that throws CancellationError on its own
            // is an ordinary failure, or that screenshot would stay unfinished and block every run.
            throw CancellationError()
        } catch {
            try await store.markFailed(id: id, reason: String(describing: error))
        }
    }

    /// Labels for screenshots with little text. They are extra search text, so if Vision
    /// fails twice the screenshot is indexed without them instead of being marked failed.
    private func optionalLabels(forImageAt url: URL, ocr: String) async throws -> [String] {
        guard ocr.count < config.shortOCRLength else { return [] }
        do {
            return try await withRetry { try await labeler.labels(forImageAt: url) }
        } catch is CancellationError where Task.isCancelled {
            throw CancellationError()
        } catch {
            return []
        }
    }

    /// Runs `work` once more if it fails. Only model work goes through here: a failed
    /// database save is a real problem, not a flaky one, so it is never retried.
    private func withRetry<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is CancellationError where Task.isCancelled {
            throw CancellationError()
        } catch {
            // A cancel during the first attempt shouldn't start a second one.
            try Task.checkCancellation()
            return try await work()
        }
    }
}
