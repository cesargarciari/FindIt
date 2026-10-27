import Foundation
import GRDB
import Testing
@testable import FindItCore

struct ScreenshotStoreTests {
    private let queue: DatabaseQueue
    private let store: ScreenshotStore

    init() throws {
        queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        store = ScreenshotStore(queue)
    }

    private func fetch(_ id: Int64) async throws -> Screenshot? {
        try await queue.read { db in try Screenshot.fetchOne(db, key: id) }
    }

    private func count(_ sql: String) async throws -> Int {
        try await queue.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    @Test func insertPendingReturnsIdAndSavesPendingRow() async throws {
        let id = try #require(try await store.insertPending(path: "/shots/a.png", fileHash: "hash-a"))

        let row = try #require(try await fetch(id))
        #expect(row.path == "/shots/a.png")
        #expect(row.fileHash == "hash-a")
        #expect(row.status == .pending)
    }

    @Test func newScreenshotHasNoFailures() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))

        #expect(try await fetch(id)?.failCount == 0)
    }

    @Test func insertPendingReturnsNilForDuplicateHash() async throws {
        let first = try await store.insertPending(path: "/shots/a.png", fileHash: "same")
        let second = try await store.insertPending(path: "/shots/copy-of-a.png", fileHash: "same")

        #expect(first != nil)
        #expect(second == nil)
        #expect(try await count("SELECT COUNT(*) FROM screenshots") == 1)
    }

    @Test func nextUnfinishedSkipsIndexedAndFailedAndPicksLowestId() async throws {
        let indexed = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        let failed = try #require(try await store.insertPending(path: "/b.png", fileHash: "b"))
        let ocrDone = try #require(try await store.insertPending(path: "/c.png", fileHash: "c"))
        _ = try await store.insertPending(path: "/d.png", fileHash: "d")
        try await queue.write { db in
            try db.execute(sql: "UPDATE screenshots SET status = 'indexed' WHERE id = ?", arguments: [indexed])
            try db.execute(sql: "UPDATE screenshots SET status = 'failed' WHERE id = ?", arguments: [failed])
            try db.execute(sql: "UPDATE screenshots SET status = 'ocr_done' WHERE id = ?", arguments: [ocrDone])
        }

        #expect(try await store.nextUnfinished()?.id == ocrDone)
    }

    @Test func nextUnfinishedIncludesDescribed() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await queue.write { db in
            try db.execute(sql: "UPDATE screenshots SET status = 'described' WHERE id = ?", arguments: [id])
        }

        #expect(try await store.nextUnfinished()?.id == id)
    }

    @Test func nextUnfinishedIsNilWhenEverythingIsDone() async throws {
        #expect(try await store.nextUnfinished() == nil)
    }

    @Test func saveOCRWritesTextAndStatusOnly() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await queue.write { db in
            try db.execute(sql: "UPDATE screenshots SET description = 'kept' WHERE id = ?", arguments: [id])
        }

        try await store.saveOCR(id: id, text: "Hola\nFindIt")

        let row = try #require(try await fetch(id))
        #expect(row.ocrText == "Hola\nFindIt")
        #expect(row.status == .ocrDone)
        #expect(row.description == "kept")
    }

    @Test func saveDescriptionWritesResultModelAndStatus() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await store.saveOCR(id: id, text: "Total 42")
        let result = DescribeResult(description: "A receipt", category: "document", language: "es", entities: ["Café Ñu", "2026"])

        try await store.saveDescription(id: id, result: result, model: "qwen3-vl:8b")

        let row = try #require(try await fetch(id))
        #expect(row.description == "A receipt")
        #expect(row.category == "document")
        #expect(row.language == "es")
        #expect(row.describerModel == "qwen3-vl:8b")
        #expect(row.status == .described)
        #expect(row.ocrText == "Total 42")
        let entities = try JSONDecoder().decode([String].self, from: Data(try #require(row.entities).utf8))
        #expect(entities == ["Café Ñu", "2026"])
    }

    @Test func saveIndexedWritesLabelsEmbeddingFTSAndStatus() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))

        try await store.saveIndexed(id: id, labels: ["document", "text"], searchableText: "Café receipt", vector: [0.6, -0.8], model: "bge-m3")

        let row = try #require(try await fetch(id))
        #expect(row.labels == ["document", "text"])
        #expect(row.status == .indexed)
        #expect(row.indexedAt != nil)

        let (model, dims, vector, ftsMatch) = try await queue.read { db in
            let embedding = try #require(try Row.fetchOne(db, sql: "SELECT model, dims, vector FROM embeddings WHERE screenshot_id = ?", arguments: [id]))
            // The FTS rowid must equal the screenshot id, because keyword search returns rowids.
            let match = try Int64.fetchOne(db, sql: "SELECT rowid FROM screenshots_fts WHERE screenshots_fts MATCH 'cafe'")
            return (embedding["model"] as String, embedding["dims"] as Int, embedding["vector"] as Data, match)
        }
        #expect(model == "bge-m3")
        #expect(dims == 2)
        #expect(ScreenshotStore.decodeVector(vector) == [0.6, -0.8])
        #expect(ftsMatch == id)
    }

    @Test func saveIndexedClearsOldFailReason() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await queue.write { db in
            try db.execute(sql: "UPDATE screenshots SET fail_reason = 'timed out' WHERE id = ?", arguments: [id])
        }

        try await store.saveIndexed(id: id, labels: [], searchableText: "x", vector: [1], model: "m")

        let row = try #require(try await fetch(id))
        #expect(row.failReason == nil)
        #expect(row.status == .indexed)
    }

    @Test func saveIndexedTwiceReplacesEmbeddingAndFTSRow() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))

        try await store.saveIndexed(id: id, labels: [], searchableText: "old", vector: [1, 0], model: "bge-m3")
        try await store.saveIndexed(id: id, labels: [], searchableText: "new", vector: [0, 1], model: "bge-m3")

        #expect(try await count("SELECT COUNT(*) FROM embeddings") == 1)
        #expect(try await count("SELECT COUNT(*) FROM screenshots_fts") == 1)
        #expect(try await count("SELECT COUNT(*) FROM screenshots_fts WHERE screenshots_fts MATCH 'new'") == 1)
    }

    @Test func saveIndexedWritesNothingWhenAnyPartFails() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        // Makes the last write in the transaction fail, after the embedding and FTS rows went in.
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_indexing BEFORE UPDATE OF status ON screenshots
                WHEN NEW.status = 'indexed' BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }

        await #expect(throws: DatabaseError.self) {
            try await store.saveIndexed(id: id, labels: ["document"], searchableText: "receipt", vector: [1, 0], model: "bge-m3")
        }

        let row = try #require(try await fetch(id))
        #expect(row.status == .pending)
        #expect(row.labels == nil)
        #expect(row.indexedAt == nil)
        #expect(try await count("SELECT COUNT(*) FROM embeddings") == 0)
        #expect(try await count("SELECT COUNT(*) FROM screenshots_fts") == 0)
    }

    @Test func helpersThrowForUnknownId() async throws {
        await #expect(throws: StoreError.screenshotNotFound(99)) {
            try await store.saveOCR(id: 99, text: "x")
        }
        await #expect(throws: StoreError.screenshotNotFound(99)) {
            try await store.saveDescription(
                id: 99,
                result: DescribeResult(description: "", category: "", language: "", entities: []),
                model: "m"
            )
        }
        await #expect(throws: StoreError.screenshotNotFound(99)) {
            try await store.saveIndexed(id: 99, labels: [], searchableText: "x", vector: [1], model: "m")
        }
        await #expect(throws: StoreError.screenshotNotFound(99)) {
            try await store.markFailed(id: 99, reason: "boom")
        }
        #expect(try await count("SELECT COUNT(*) FROM screenshots_fts") == 0)
    }

    @Test func markFailedWritesStatusReasonAndCountOnly() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await store.saveOCR(id: id, text: "kept")

        try await store.markFailed(id: id, reason: "boom")

        let row = try #require(try await fetch(id))
        #expect(row.status == .failed)
        #expect(row.failReason == "boom")
        #expect(row.failCount == 1)
        #expect(row.ocrText == "kept")
    }

    @Test func markFailedCountsEachFailure() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))

        try await store.markFailed(id: id, reason: "first")
        try await store.markFailed(id: id, reason: "second")

        let row = try #require(try await fetch(id))
        #expect(row.failCount == 2)
        #expect(row.failReason == "second")
    }

    @Test func markFailedCapsReason() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))

        try await store.markFailed(id: id, reason: String(repeating: "é", count: 5000))

        #expect(try await fetch(id)?.failReason?.count == 1000)
    }

    @Test func resetFailedMakesFailedPendingAgainAndCountsThem() async throws {
        let statuses = ["failed", "indexed", "failed", "ocr_done"]
        try await queue.write { db in
            for (index, status) in statuses.enumerated() {
                try db.execute(
                    sql: "INSERT INTO screenshots (path, file_hash, created_at, status, fail_reason, ocr_text) VALUES (?, ?, 0, ?, ?, 'kept')",
                    arguments: ["/\(index).png", "h\(index)", status, status == "failed" ? "boom" : nil]
                )
            }
        }

        #expect(try await store.resetFailed() == 2)

        let rows = try await queue.read { db in try Screenshot.order(Column("id")).fetchAll(db) }
        #expect(rows.map(\.status) == [.pending, .indexed, .pending, .ocrDone])
        #expect(rows.allSatisfy { $0.failReason == nil })
        // Reset rows start clean; the others keep their results.
        #expect(rows.map(\.ocrText) == [nil, "kept", nil, "kept"])
    }

    @Test func resetFailedClearsEveryEarlierResult() async throws {
        let id = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await store.saveOCR(id: id, text: "Total 42")
        try await store.saveDescription(
            id: id,
            result: DescribeResult(description: "A receipt", category: "document", language: "en", entities: ["Ñu"]),
            model: "qwen3-vl:8b"
        )
        // Leftover rows that a reset screenshot must not keep, or search could still return it.
        try await queue.write { db in
            try db.execute(sql: "UPDATE screenshots SET labels = '[\"text\"]', indexed_at = 0, status = 'failed' WHERE id = ?", arguments: [id])
            try db.execute(sql: "INSERT INTO embeddings (screenshot_id, model, dims, vector) VALUES (?, 'bge-m3', 1, x'0000803f')", arguments: [id])
            try db.execute(sql: "INSERT INTO screenshots_fts (rowid, searchable_text) VALUES (?, 'receipt')", arguments: [id])
        }

        #expect(try await store.resetFailed() == 1)

        let row = try #require(try await fetch(id))
        #expect(row.status == .pending)
        #expect(row.ocrText == nil)
        #expect(row.description == nil)
        #expect(row.category == nil)
        #expect(row.language == nil)
        #expect(row.entities == nil)
        #expect(row.describerModel == nil)
        #expect(row.labels == nil)
        #expect(row.indexedAt == nil)
        #expect(try await count("SELECT COUNT(*) FROM embeddings") == 0)
        #expect(try await count("SELECT COUNT(*) FROM screenshots_fts") == 0)
    }

    @Test func resetFailedLeavesScreenshotsThatFailedTooOften() async throws {
        try await queue.write { db in
            for (index, failCount) in [1, 2, 3, 7].enumerated() {
                try db.execute(
                    sql: "INSERT INTO screenshots (path, file_hash, created_at, status, fail_reason, fail_count) VALUES (?, ?, 0, 'failed', 'boom', ?)",
                    arguments: ["/\(index).png", "h\(index)", failCount]
                )
            }
        }

        #expect(try await store.resetFailed() == 2)

        let rows = try await queue.read { db in try Screenshot.order(Column("id")).fetchAll(db) }
        #expect(rows.map(\.status) == [.pending, .pending, .failed, .failed])
        // Kept, so the user can still see why a given-up screenshot failed.
        #expect(rows.map(\.failReason) == [nil, nil, "boom", "boom"])
        // The count survives a reset, otherwise the limit would never be reached.
        #expect(rows.map(\.failCount) == [1, 2, 3, 7])
    }

    @Test func resetFailedReturnsZeroWhenNothingFailed() async throws {
        _ = try await store.insertPending(path: "/a.png", fileHash: "a")

        #expect(try await store.resetFailed() == 0)
        #expect(try await store.nextUnfinished()?.status == .pending)
    }

    @Test func allEmbeddingsReturnsIndexedVectorsForThatModelOnly() async throws {
        let indexed = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        let otherModel = try #require(try await store.insertPending(path: "/b.png", fileHash: "b"))
        let failedLater = try #require(try await store.insertPending(path: "/c.png", fileHash: "c"))
        try await store.saveIndexed(id: indexed, labels: [], searchableText: "a", vector: [0.6, 0.8], model: "bge-m3")
        try await store.saveIndexed(id: otherModel, labels: [], searchableText: "b", vector: [1, 0], model: "nomic-embed-text")
        try await store.saveIndexed(id: failedLater, labels: [], searchableText: "c", vector: [0, 1], model: "bge-m3")
        // A vector whose screenshot isn't indexed any more must not show up in search.
        try await store.markFailed(id: failedLater, reason: "boom")

        let vectors = try await store.allEmbeddings(model: "bge-m3")

        #expect(vectors == [indexed: [0.6, 0.8]])
    }

    @Test func allEmbeddingsIsEmptyWithoutVectors() async throws {
        _ = try await store.insertPending(path: "/a.png", fileHash: "a")

        #expect(try await store.allEmbeddings(model: "bge-m3").isEmpty)
    }

    @Test func pathsReturnsStoredPathsAndLeavesOutUnknownIds() async throws {
        let a = try #require(try await store.insertPending(path: "/shots/cafe\u{301}.png", fileHash: "a"))
        let b = try #require(try await store.insertPending(path: "/shots/b.png", fileHash: "b"))

        let paths = try await store.paths(for: [b, 999, a])

        // Paths come back as stored, which is NFC.
        #expect(paths == [a: "/shots/caf\u{E9}.png", b: "/shots/b.png"])
        #expect(paths[a].map { Array($0.utf8) } == Array("/shots/caf\u{E9}.png".utf8))
    }

    @Test func pathsForNoIdsIsEmpty() async throws {
        #expect(try await store.paths(for: []).isEmpty)
    }

    @Test func failureReasonsCountsFailedScreenshotsByReason() async throws {
        for (hash, reason) in [("a", "timedOut"), ("b", "timedOut"), ("c", "emptyEmbedding")] {
            let id = try #require(try await store.insertPending(path: "/\(hash).png", fileHash: hash))
            try await store.markFailed(id: id, reason: reason)
        }
        _ = try await store.insertPending(path: "/pending.png", fileHash: "p")

        #expect(try await store.failureReasons() == ["timedOut": 2, "emptyEmbedding": 1])
    }

    @Test func fileHashesReturnsStoredHashesAndLeavesOutUnknownIds() async throws {
        let a = try #require(try await store.insertPending(path: "/a.png", fileHash: "hash-a"))
        let b = try #require(try await store.insertPending(path: "/b.png", fileHash: "hash-b"))

        #expect(try await store.fileHashes(for: [b, 999, a]) == [a: "hash-a", b: "hash-b"])
        #expect(try await store.fileHashes(for: []).isEmpty)
    }

    @Test func statusesByHashLeavesOutUnknownHashes() async throws {
        let indexed = try #require(try await store.insertPending(path: "/a.png", fileHash: "hash-a"))
        let failed = try #require(try await store.insertPending(path: "/b.png", fileHash: "hash-b"))
        _ = try await store.insertPending(path: "/c.png", fileHash: "hash-c")
        try await store.saveIndexed(id: indexed, labels: [], searchableText: "a", vector: [1], model: "m")
        try await store.markFailed(id: failed, reason: "boom")

        let statuses = try await store.statuses(forHashes: ["hash-a", "hash-b", "hash-c", "unknown"])

        #expect(statuses == ["hash-a": .indexed, "hash-b": .failed, "hash-c": .pending])
        #expect(try await store.statuses(forHashes: []).isEmpty)
    }

    @Test func progressCountsGroupsUnfinishedAsPending() async throws {
        let statuses = ["pending", "ocr_done", "described", "indexed", "indexed", "failed"]
        try await queue.write { db in
            for (index, status) in statuses.enumerated() {
                try db.execute(
                    sql: "INSERT INTO screenshots (path, file_hash, created_at, status) VALUES (?, ?, 0, ?)",
                    arguments: ["/\(index).png", "h\(index)", status]
                )
            }
        }

        #expect(try await store.progressCounts() == ProgressCounts(pending: 3, indexed: 2, failed: 1))
    }

    @Test func descriptionsReturnsStoredOnesAndLeavesOutTheRest() async throws {
        let described = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        let pending = try #require(try await store.insertPending(path: "/b.png", fileHash: "b"))
        let result = DescribeResult(description: "A receipt", category: "document", language: "en", entities: [])
        try await store.saveDescription(id: described, result: result, model: "qwen3-vl:8b")

        let descriptions = try await store.descriptions(for: [described, pending, 999])

        #expect(descriptions == [described: "A receipt"])
    }

    @Test func descriptionsForNoIdsIsEmpty() async throws {
        #expect(try await store.descriptions(for: []).isEmpty)
    }
}
