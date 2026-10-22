import Foundation
import GRDB
import Testing
@testable import FindItCore

/// Cancels the task it runs in, then throws CancellationError, as a step does on a real cancel.
private struct CancellingRecognizer: TextRecognizing {
    func recognizeText(at url: URL) async throws -> String {
        withUnsafeCurrentTask { $0?.cancel() }
        throw CancellationError()
    }
}

/// Throws CancellationError although nothing cancelled the task, as a dependency might by mistake.
private final class StrayCancellationRecognizer: TextRecognizing {
    let calls = FakeCalls(failure: .never)

    func recognizeText(at url: URL) async throws -> String {
        try calls.record()
        throw CancellationError()
    }
}

/// The same stray CancellationError, from the labeling step.
private final class StrayCancellationLabeler: ImageLabeling {
    let calls = FakeCalls(failure: .never)

    func labels(forImageAt url: URL) async throws -> [String] {
        try calls.record()
        throw CancellationError()
    }
}

/// Cancels the task it runs in, then fails with an ordinary error, as Vision might when interrupted.
private final class CancelThenFailRecognizer: TextRecognizing {
    let calls = FakeCalls(failure: .always)

    func recognizeText(at url: URL) async throws -> String {
        withUnsafeCurrentTask { $0?.cancel() }
        try calls.record()
        return ""
    }
}

struct IndexQueueTests {
    private let db: DatabaseQueue

    init() throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
    }

    private func makeQueue(
        recognizer: any TextRecognizing = FakeTextRecognizer(),
        describer: any ImageDescribing = FakeImageDescriber(),
        labeler: any ImageLabeling = FakeImageLabeler(),
        embedder: any TextEmbedding = FakeTextEmbedder(),
        config: IndexConfig = IndexConfig()
    ) -> IndexQueue {
        IndexQueue(db: db, recognizer: recognizer, describer: describer, labeler: labeler, embedder: embedder, config: config)
    }

    /// A blank PNG. Different widths give different bytes, so different hashes.
    private func writeImage(in folder: URL, name: String, width: Int = 64) throws -> URL {
        let url = folder.appending(path: name)
        try TestImages.write(TestImages.make(width: width, height: 48), to: url)
        return url
    }

    private func rows() async throws -> [Screenshot] {
        try await db.read { db in try Screenshot.order(Column("id")).fetchAll(db) }
    }

    private func ftsText(_ id: Int64) async throws -> String? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT searchable_text FROM screenshots_fts WHERE rowid = ?", arguments: [id])
        }
    }

    private func blockStatusUpdates(when condition: String = "1") async throws {
        try await db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER block_status BEFORE UPDATE OF status ON screenshots
                WHEN \(condition) BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
    }

    /// Enqueues one image and runs the queue to the end. The image only exists until this returns.
    private func indexOneImage(with queue: IndexQueue) async throws -> Screenshot {
        try await withTemporaryDirectory { folder in
            let url = try writeImage(in: folder, name: "shot.png")
            #expect(try await queue.enqueue([url]).added == 1)
            try await queue.run()
            return try #require(try await rows().first)
        }
    }

    // MARK: Full pipeline

    @Test func fullPipelineIndexesScreenshot() async throws {
        let recognizer = FakeTextRecognizer()
        let describer = FakeImageDescriber()
        let labeler = FakeImageLabeler()
        let embedder = FakeTextEmbedder()
        let queue = makeQueue(recognizer: recognizer, describer: describer, labeler: labeler, embedder: embedder)

        let row = try await indexOneImage(with: queue)

        #expect(row.status == .indexed)
        #expect(row.ocrText == "Hola FindIt")
        #expect(row.description == "A receipt")
        #expect(row.category == "document")
        #expect(row.language == "en")
        #expect(row.describerModel == "qwen3-vl:8b")
        #expect(row.labels == ["document"])
        #expect(row.failReason == nil)
        #expect(row.indexedAt != nil)

        let id = try #require(row.id)
        let (model, match) = try await db.read { db in
            (
                try String.fetchOne(db, sql: "SELECT model FROM embeddings WHERE screenshot_id = ?", arguments: [id]),
                try Int64.fetchOne(db, sql: "SELECT rowid FROM screenshots_fts WHERE screenshots_fts MATCH 'receipt'")
            )
        }
        #expect(model == "bge-m3")
        #expect(match == id)
        #expect(recognizer.callCount == 1)
        #expect(describer.callCount == 1)
        #expect(labeler.callCount == 1)
        #expect(embedder.callCount == 1)
    }

    // MARK: Retry boundaries

    @Test func malformedDescriptionAsksModelAgain() async throws {
        let describer = FakeImageDescriber(response: "not json")

        let row = try await indexOneImage(with: makeQueue(describer: describer))

        #expect(describer.callCount == 2)
        #expect(row.status == .failed)
        #expect(row.failCount == 1)
    }

    @Test func failedSaveIsNotRetried() async throws {
        try await blockStatusUpdates(when: "NEW.status = 'ocr_done'")
        let recognizer = FakeTextRecognizer()

        let row = try await indexOneImage(with: makeQueue(recognizer: recognizer))

        #expect(recognizer.callCount == 1)
        #expect(row.status == .failed)
        #expect(row.failReason?.contains("boom") == true)
    }

    @Test func ftsGetsTextWithoutPrefix() async throws {
        var config = IndexConfig()
        config.embedderModel = "nomic-embed-text"
        let embedder = FakeTextEmbedder()

        let row = try await indexOneImage(with: makeQueue(embedder: embedder, config: config))

        let expected = searchableText(ocr: "Hola FindIt", description: "A receipt", labels: ["document"])
        #expect(embedder.receivedTexts == [["search_document: " + expected]])
        #expect(try await ftsText(try #require(row.id)) == expected)
    }

    // MARK: Labeling

    @Test func labelerFailureStillIndexes() async throws {
        let labeler = FakeImageLabeler(failure: .always)

        let row = try await indexOneImage(with: makeQueue(labeler: labeler))

        #expect(row.status == .indexed)
        #expect(row.labels == [])
        #expect(row.failReason == nil)
        #expect(labeler.callCount == 2)
    }

    @Test func labelerSucceedsOnRetry() async throws {
        let labeler = FakeImageLabeler(failure: .firstCalls(1))

        let row = try await indexOneImage(with: makeQueue(labeler: labeler))

        #expect(row.labels == ["document"])
        #expect(labeler.callCount == 2)
    }

    @Test func longOCRSkipsLabeler() async throws {
        // Exactly the threshold already counts as enough text.
        let recognizer = FakeTextRecognizer(text: String(repeating: "a", count: IndexConfig().shortOCRLength))
        let labeler = FakeImageLabeler()

        let row = try await indexOneImage(with: makeQueue(recognizer: recognizer, labeler: labeler))

        #expect(row.status == .indexed)
        #expect(row.labels == [])
        #expect(labeler.callCount == 0)
    }

    // MARK: Retries and failures

    @Test func flakyModelCallsAreRetriedOnce() async throws {
        let recognizer = FakeTextRecognizer(failure: .firstCalls(1))
        let describer = FakeImageDescriber(failure: .firstCalls(1))
        let embedder = FakeTextEmbedder(failure: .firstCalls(1))

        let row = try await indexOneImage(with: makeQueue(recognizer: recognizer, describer: describer, embedder: embedder))

        #expect(row.status == .indexed)
        #expect(row.failCount == 0)
        #expect(recognizer.callCount == 2)
        #expect(describer.callCount == 2)
        #expect(embedder.callCount == 2)
    }

    @Test func stepFailingTwiceMarksFailedAndQueueContinues() async throws {
        let describer = FakeImageDescriber(failure: .firstCalls(2))
        let queue = makeQueue(describer: describer)

        let result = try await withTemporaryDirectory { folder in
            let first = try writeImage(in: folder, name: "a.png", width: 64)
            let second = try writeImage(in: folder, name: "b.png", width: 65)
            #expect(try await queue.enqueue([first, second]).added == 2)
            try await queue.run()
            return try await rows()
        }

        #expect(result.map(\.status) == [.failed, .indexed])
        #expect(result.map(\.failCount) == [1, 0])
        #expect(result.first?.failReason?.contains("FakeError") == true)
        #expect(describer.callCount == 3)
    }

    @Test func emptyEmbeddingMarksFailed() async throws {
        let embedder = FakeTextEmbedder(vector: [])

        let row = try await indexOneImage(with: makeQueue(embedder: embedder))

        #expect(row.status == .failed)
        #expect(row.failReason == "emptyEmbedding")
        #expect(embedder.callCount == 2)
        let stored = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") }
        #expect(stored == 0)
    }

    @Test func vectorIsNormalizedBeforeSaving() async throws {
        let row = try await indexOneImage(with: makeQueue(embedder: FakeTextEmbedder(vector: [3, 4])))

        let id = try #require(row.id)
        let data = try await db.read { db in
            try Data.fetchOne(db, sql: "SELECT vector FROM embeddings WHERE screenshot_id = ?", arguments: [id])
        }
        let vector = ScreenshotStore.decodeVector(try #require(data))
        try #require(vector.count == 2)
        #expect(abs(vector[0] - 0.6) < 1e-6)
        #expect(abs(vector[1] - 0.8) < 1e-6)
    }

    // MARK: Run loop

    // The time limit turns a regression of the infinite-loop guard into a failure instead of a hang.
    @Test(.timeLimit(.minutes(1)))
    func runThrowsWhenFailureCannotBeSaved() async throws {
        // Blocks every status change, including the one that marks the screenshot failed.
        try await blockStatusUpdates()
        let recognizer = FakeTextRecognizer()
        let queue = makeQueue(recognizer: recognizer)

        let row = try await withTemporaryDirectory { folder in
            _ = try await queue.enqueue([try writeImage(in: folder, name: "shot.png")])
            let id = try #require(try await rows().first?.id)
            await #expect {
                try await queue.run()
            } throws: { error in
                // The reason carries the database error, so the caller can say why indexing stopped.
                if case IndexQueueError.cannotRecordFailure(id, let reason) = error {
                    reason.contains("boom")
                } else {
                    false
                }
            }
            return try #require(try await rows().first)
        }

        #expect(row.status == .pending)
        #expect(row.failCount == 0)
        #expect(recognizer.callCount == 1)
    }

    // The time limit turns a second run() that waits at the gate into a failure instead of a hang.
    @Test(.timeLimit(.minutes(1)))
    func secondRunReturnsAtOnceAndWorkAddedDuringRunIsIndexed() async throws {
        let recognizer = GatedTextRecognizer()
        let queue = makeQueue(recognizer: recognizer)

        let saved = try await withTemporaryDirectory { folder in
            let first = try writeImage(in: folder, name: "a.png", width: 64)
            let second = try writeImage(in: folder, name: "b.png", width: 65)
            _ = try await queue.enqueue([first])
            let firstRun = Task { try await queue.run() }
            await recognizer.waitForWaitingCall()

            // The first run is suspended in OCR, so this call must return without doing any work.
            try await queue.run()
            #expect(recognizer.callCount == 1)

            #expect(try await queue.enqueue([second]).added == 1)
            recognizer.release()
            try await firstRun.value
            return try await rows()
        }

        #expect(saved.map(\.status) == [.indexed, .indexed])
        #expect(recognizer.callCount == 2)
    }

    @Test func runThrowsWhenDatabaseCannotBeRead() async throws {
        try await db.write { db in try db.execute(sql: "DROP TABLE screenshots") }

        await #expect(throws: DatabaseError.self) { try await makeQueue().run() }
    }

    @Test func cancellationLeavesScreenshotUnfailed() async throws {
        let queue = makeQueue(recognizer: CancellingRecognizer())

        let row = try await withTemporaryDirectory { folder in
            _ = try await queue.enqueue([try writeImage(in: folder, name: "shot.png")])
            // Its own task, so the cancel doesn't reach this test's later reads.
            try await Task { try await queue.run() }.value
            return try #require(try await rows().first)
        }

        #expect(row.status == .pending)
        #expect(row.failCount == 0)
        #expect(row.failReason == nil)
    }

    @Test func strayCancellationErrorIsAnOrdinaryFailure() async throws {
        let recognizer = StrayCancellationRecognizer()

        let row = try await indexOneImage(with: makeQueue(recognizer: recognizer))

        // Nothing cancelled the task, so this is a failing step: retried once, then saved as failed.
        #expect(recognizer.calls.count == 2)
        #expect(row.status == .failed)
        #expect(row.failCount == 1)
        #expect(row.failReason?.contains("CancellationError") == true)
    }

    @Test func strayCancellationFromLabelerStillIndexes() async throws {
        let labeler = StrayCancellationLabeler()

        let row = try await indexOneImage(with: makeQueue(labeler: labeler))

        #expect(row.status == .indexed)
        #expect(row.labels == [])
        #expect(labeler.calls.count == 2)
    }

    @Test func cancelledTaskIsNotRetriedOrMarkedFailed() async throws {
        let recognizer = CancelThenFailRecognizer()
        let queue = makeQueue(recognizer: recognizer)

        let row = try await withTemporaryDirectory { folder in
            let url = try writeImage(in: folder, name: "shot.png")
            _ = try await queue.enqueue([url])
            // Its own task, so the cancel doesn't reach this test's later reads.
            try await Task { try await queue.run() }.value
            return try #require(try await rows().first)
        }

        #expect(recognizer.calls.count == 1)
        #expect(row.status == .pending)
        #expect(row.failCount == 0)
    }

    @Test func resumesFromSavedStatus() async throws {
        // Long OCR text skips the labeler, so the missing file is never read.
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO screenshots (path, file_hash, created_at, status, ocr_text, description)
                VALUES ('/missing.png', 'h', 0, 'described', 'Total 42 at Café Ñu in Calgary', 'A receipt')
                """)
        }
        let recognizer = FakeTextRecognizer()
        let describer = FakeImageDescriber()
        let labeler = FakeImageLabeler()
        let embedder = FakeTextEmbedder()
        let queue = makeQueue(recognizer: recognizer, describer: describer, labeler: labeler, embedder: embedder)

        try await queue.run()

        #expect(try await rows().map(\.status) == [.indexed])
        #expect(recognizer.callCount == 0)
        #expect(describer.callCount == 0)
        #expect(labeler.callCount == 0)
        #expect(embedder.callCount == 1)
    }

    // MARK: Enqueue

    @Test func enqueueCountsOnlyNewImages() async throws {
        let queue = makeQueue()

        let (first, second, saved) = try await withTemporaryDirectory { folder in
            let a = try writeImage(in: folder, name: "a.png", width: 64)
            let b = try writeImage(in: folder, name: "b.png", width: 65)
            let copyOfA = folder.appending(path: "copy-of-a.png")
            try FileManager.default.copyItem(at: a, to: copyOfA)
            let first = try await queue.enqueue([a, b, copyOfA])
            let second = try await queue.enqueue([a])
            return (first, second, try await rows())
        }

        #expect(first == EnqueueResult(added: 2, skipped: []))
        #expect(second == EnqueueResult(added: 0, skipped: []))
        #expect(saved.map(\.status) == [.pending, .pending])
    }

    @Test func enqueueSkipsUnreadableFileAndKeepsGoing() async throws {
        let queue = makeQueue()
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).png")

        let (result, saved) = try await withTemporaryDirectory { folder in
            let good = try writeImage(in: folder, name: "good.png")
            return (try await queue.enqueue([missing, good]), try await rows())
        }

        #expect(result == EnqueueResult(added: 1, skipped: [missing.path]))
        #expect(saved.map(\.status) == [.pending])
    }

    // MARK: Real Vision

    @Test func indexesWithRealVision() async throws {
        let row = try await withTemporaryDirectory { folder in
            let url = folder.appending(path: "text.png")
            try TestImages.write(try TestImages.text("Hola FindIt 2026"), to: url)
            // Real OCR, labels and resizing; only the Ollama calls are faked.
            let queue = makeQueue(recognizer: OCRService(), labeler: Labeler())
            _ = try await queue.enqueue([url])
            try await queue.run()
            return try #require(try await rows().first)
        }

        #expect(row.status == .indexed)
        #expect(row.ocrText?.contains("FindIt") == true)
        #expect(row.failReason == nil)
    }
}
