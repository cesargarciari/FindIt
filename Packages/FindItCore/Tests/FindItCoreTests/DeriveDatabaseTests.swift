import Foundation
import GRDB
import Testing
@testable import FindItCore

struct DeriveDatabaseTests {
    private struct Ids {
        let indexed: Int64
        let described: Int64
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

        let failedAfterOCR = try #require(try await store.insertPending(path: "/c.png", fileHash: "c"))
        try await store.saveOCR(id: failedAfterOCR, text: "")
        try await store.markFailed(id: failedAfterOCR, reason: "decodingFailed")

        let failedBeforeOCR = try #require(try await store.insertPending(path: "/d.png", fileHash: "d"))
        try await store.markFailed(id: failedBeforeOCR, reason: "cannotRead")

        let pending = try #require(try await store.insertPending(path: "/e.png", fileHash: "e"))
        return Ids(indexed: indexed, described: described, failedAfterOCR: failedAfterOCR, failedBeforeOCR: failedBeforeOCR, pending: pending)
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

            #expect(result == DeriveResult(resetIndexed: 1, resetFailed: 0))
            let shots = try rows(in: target)
            let wasIndexed = try #require(shots[ids.indexed])
            #expect(wasIndexed.status == .described)
            #expect(wasIndexed.description == "A receipt")
            #expect(wasIndexed.describerModel == "qwen3-vl:8b")
            #expect(wasIndexed.ocrText == "Total 42")
            #expect(wasIndexed.indexedAt == nil)
            #expect(shots[ids.described]?.status == .described)
            // Only ocr_done gives failed screenshots another try.
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

            #expect(result == DeriveResult(resetIndexed: 1, resetFailed: 1))
            let shots = try rows(in: target)
            for id in [ids.indexed, ids.failedAfterOCR] {
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
