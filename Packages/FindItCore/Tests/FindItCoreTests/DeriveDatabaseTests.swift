import Foundation
import GRDB
import Testing
@testable import FindItCore

private enum SourceFile {
    static func execute(at url: URL, sql: String, arguments: StatementArguments) async throws {
        try await DatabaseQueue(path: url.path).write { db in try db.execute(sql: sql, arguments: arguments) }
    }
}

struct DeriveDatabaseTests {
    private struct Ids {
        let indexed: Int64
        let described: Int64
        let failedAfterDescribe: Int64
        let failedAfterOCR: Int64
        let failedBeforeOCR: Int64
        let pending: Int64
    }

    /// One screenshot in each state a finished eval run can leave behind.
    private func makeSource(at url: URL) async throws -> Ids {
        let store = ScreenshotStore(try AppDatabase.open(atPath: url.path))
        let result = DescribeResult(description: "A receipt", category: "document", language: "en", entities: ["Café Ñu"])

        let indexed = try #require(try await store.insertPending(path: "/a.png", fileHash: "a"))
        try await store.saveOCR(id: indexed, text: "Total 42")
        try await store.saveDescription(id: indexed, result: result, model: "qwen3-vl:8b")
        try await store.saveIndexed(id: indexed, labels: ["document"], searchableText: "A receipt Total 42", vector: [1, 0], model: "bge-m3")

        let described = try #require(try await store.insertPending(path: "/b.png", fileHash: "b"))
        try await store.saveOCR(id: described, text: "Hola")
        try await store.saveDescription(id: described, result: result, model: "qwen3-vl:8b")

        let failedAfterDescribe = try #require(try await store.insertPending(path: "/f.png", fileHash: "f"))
        try await store.saveOCR(id: failedAfterDescribe, text: "Hola")
        try await store.saveDescription(id: failedAfterDescribe, result: result, model: "qwen3-vl:8b")
        try await store.markFailed(id: failedAfterDescribe, reason: "emptyEmbedding")

        let failedAfterOCR = try #require(try await store.insertPending(path: "/c.png", fileHash: "c"))
        try await store.saveOCR(id: failedAfterOCR, text: "")
        try await store.markFailed(id: failedAfterOCR, reason: "decodingFailed")

        let failedBeforeOCR = try #require(try await store.insertPending(path: "/d.png", fileHash: "d"))
        try await store.markFailed(id: failedBeforeOCR, reason: "cannotRead")

        let pending = try #require(try await store.insertPending(path: "/e.png", fileHash: "e"))
        // Earlier failures on rows derive retries, so the tests can check fail_count goes back to 0.
        try await SourceFile.execute(at: url, sql: "UPDATE screenshots SET fail_count = 2 WHERE id IN (?, ?)", arguments: [indexed, described])
        return Ids(
            indexed: indexed,
            described: described,
            failedAfterDescribe: failedAfterDescribe,
            failedAfterOCR: failedAfterOCR,
            failedBeforeOCR: failedBeforeOCR,
            pending: pending
        )
    }

    private func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: url.path).read(body)
    }

    private func count(_ table: String, in url: URL) throws -> Int {
        try read(url) { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    private func rows(in url: URL) throws -> [Int64: Screenshot] {
        try read(url) { db in
            Dictionary(uniqueKeysWithValues: try Screenshot.fetchAll(db).map { ($0.id!, $0) })
        }
    }

    @Test func resetToDescribedKeepsDescriptionsAndRemovesIndexes() async throws {
        try await withTemporaryDirectory { folder in
            let source = folder.appending(path: "source.sqlite")
            let target = folder.appending(path: "target.sqlite")
            let ids = try await makeSource(at: source)

            let result = try deriveDatabase(from: source, to: target, resetTo: .described)

            #expect(result == DeriveResult(resetIndexed: 1, resetDescribed: 0, resetFailed: 1))
            let shots = try rows(in: target)
            let wasIndexed = try #require(shots[ids.indexed])
            #expect(wasIndexed.status == .described)
            #expect(wasIndexed.description == "A receipt")
            #expect(wasIndexed.describerModel == "qwen3-vl:8b")
            #expect(wasIndexed.ocrText == "Total 42")
            #expect(wasIndexed.indexedAt == nil)
            #expect(wasIndexed.failCount == 0)
            #expect(shots[ids.described]?.status == .described)
            // It failed at embedding, maybe because of the old embedder, so the new one gets a try.
            let failedAfterDescribe = try #require(shots[ids.failedAfterDescribe])
            #expect(failedAfterDescribe.status == .described)
            #expect(failedAfterDescribe.description == "A receipt")
            #expect(failedAfterDescribe.failReason == nil)
            #expect(failedAfterDescribe.failCount == 0)
            #expect(failedAfterDescribe.labels == nil)
            #expect(failedAfterDescribe.indexedAt == nil)
            // No description, so it never reached embedding and stays failed.
            #expect(shots[ids.failedAfterOCR]?.status == .failed)
            #expect(shots[ids.pending]?.status == .pending)
            #expect(try count("embeddings", in: target) == 0)
            #expect(try count("screenshots_fts", in: target) == 0)
        }
    }

    @Test func resetToOCRDoneClearsDescribeResultsAndRetriesFailuresWithOCR() async throws {
        try await withTemporaryDirectory { folder in
            let source = folder.appending(path: "source.sqlite")
            let target = folder.appending(path: "target.sqlite")
            let ids = try await makeSource(at: source)

            let result = try deriveDatabase(from: source, to: target, resetTo: .ocrDone)

            #expect(result == DeriveResult(resetIndexed: 1, resetDescribed: 1, resetFailed: 2))
            let shots = try rows(in: target)
            for id in [ids.indexed, ids.described, ids.failedAfterDescribe, ids.failedAfterOCR] {
                let shot = try #require(shots[id])
                #expect(shot.status == .ocrDone)
                #expect(shot.description == nil)
                #expect(shot.category == nil)
                #expect(shot.language == nil)
                #expect(shot.entities == nil)
                #expect(shot.labels == nil)
                #expect(shot.describerModel == nil)
                #expect(shot.failReason == nil)
                #expect(shot.indexedAt == nil)
                #expect(shot.failCount == 0)
            }
            #expect(shots[ids.indexed]?.ocrText == "Total 42")
            // Empty OCR text still means OCR ran.
            #expect(shots[ids.failedAfterOCR]?.ocrText == "")
            // No OCR text, so the failure happened before describing and stays.
            #expect(shots[ids.failedBeforeOCR]?.status == .failed)
            #expect(shots[ids.failedBeforeOCR]?.failReason == "cannotRead")
            #expect(try count("embeddings", in: target) == 0)
            #expect(try count("screenshots_fts", in: target) == 0)
        }
    }

    @Test func sourceIsNotChanged() async throws {
        try await withTemporaryDirectory { folder in
            let source = folder.appending(path: "source.sqlite")
            let ids = try await makeSource(at: source)

            _ = try deriveDatabase(from: source, to: folder.appending(path: "target.sqlite"), resetTo: .ocrDone)

            #expect(try rows(in: source)[ids.indexed]?.status == .indexed)
            #expect(try rows(in: source)[ids.indexed]?.description == "A receipt")
            #expect(try count("embeddings", in: source) == 1)
            #expect(try count("screenshots_fts", in: source) == 1)
        }
    }

    @Test func refusesToOverwriteExistingTarget() async throws {
        try await withTemporaryDirectory { folder in
            let source = folder.appending(path: "source.sqlite")
            let target = folder.appending(path: "target.sqlite")
            _ = try await makeSource(at: source)
            try Data("keep me".utf8).write(to: target)

            #expect(throws: DeriveError.targetExists(target.path)) {
                try deriveDatabase(from: source, to: target, resetTo: .described)
            }
            #expect(try Data(contentsOf: target) == Data("keep me".utf8))
        }
    }

    @Test func missingSourceThrowsAndCreatesNothing() throws {
        try withTemporaryDirectory { folder in
            let source = folder.appending(path: "missing.sqlite")
            let target = folder.appending(path: "target.sqlite")

            #expect(throws: DeriveError.sourceMissing(source.path)) {
                try deriveDatabase(from: source, to: target, resetTo: .described)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }
}
