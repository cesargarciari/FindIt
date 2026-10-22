import Foundation
import GRDB

public enum StoreError: Error, Equatable, Sendable {
    case screenshotNotFound(Int64)
}

/// How far indexing has got. `pending` counts every screenshot that isn't indexed or failed yet.
public struct ProgressCounts: Equatable, Sendable {
    public let pending: Int
    public let indexed: Int
    public let failed: Int
}

/// The database writes IndexQueue needs. Each one writes only its own columns, so a step
/// never overwrites what another step saved.
public struct ScreenshotStore: Sendable {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Adds a new pending screenshot and returns its id, or nil when that file hash is already stored.
    public func insertPending(path: String, fileHash: String) async throws -> Int64? {
        try await writer.write { db in
            var screenshot = Screenshot(path: path, fileHash: fileHash, createdAt: Date())
            // Ignore only applies here to the unique file_hash; every other column is always valid.
            try screenshot.insert(db, onConflict: .ignore)
            return db.changesCount == 0 ? nil : db.lastInsertedRowID
        }
    }

    /// The lowest-id screenshot that still has work left, so indexing resumes in arrival order.
    public func nextUnfinished() async throws -> Screenshot? {
        try await writer.read { db in
            try Screenshot
                .filter(![Status.indexed, Status.failed].contains(Column("status")))
                .order(Column("id"))
                .fetchOne(db)
        }
    }

    public func saveOCR(id: Int64, text: String) async throws {
        try await writer.write { db in
            try Self.update(id, in: db, [
                Column("ocr_text").set(to: text),
                Column("status").set(to: Status.ocrDone),
            ])
        }
    }

    public func saveDescription(id: Int64, result: DescribeResult, model: String) async throws {
        let entities = try Self.json(result.entities)
        try await writer.write { db in
            try Self.update(id, in: db, [
                Column("description").set(to: result.description),
                Column("category").set(to: result.category),
                Column("language").set(to: result.language),
                Column("entities").set(to: entities),
                Column("describer_model").set(to: model),
                Column("status").set(to: Status.described),
            ])
        }
    }

    /// Writes the last step's results in one transaction, so a screenshot is either fully
    /// searchable or still unfinished, never half indexed. Expects an already normalized vector.
    public func saveIndexed(id: Int64, labels: [String], searchableText: String, vector: [Float], model: String) async throws {
        let labelsJSON = try Self.json(labels)
        let vectorData = Self.encodeVector(vector)
        // GRDB runs each write closure in a transaction and rolls it back if anything throws.
        try await writer.write { db in
            // Checked first, because the embeddings foreign key would fail with a less clear error.
            guard try Screenshot.exists(db, key: id) else {
                throw StoreError.screenshotNotFound(id)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO embeddings (screenshot_id, model, dims, vector) VALUES (?, ?, ?, ?)",
                arguments: [id, model, vector.count, vectorData]
            )
            // The FTS rowid is the screenshot id, because keyword search returns rowids.
            try db.execute(sql: "DELETE FROM screenshots_fts WHERE rowid = ?", arguments: [id])
            try db.execute(
                sql: "INSERT INTO screenshots_fts (rowid, searchable_text) VALUES (?, ?)",
                arguments: [id, searchableText]
            )
            try Self.update(id, in: db, [
                Column("labels").set(to: labelsJSON),
                Column("status").set(to: Status.indexed),
                Column("indexed_at").set(to: Date()),
                // A retried screenshot shouldn't keep the reason from its earlier failure.
                Column("fail_reason").set(to: nil),
            ])
        }
    }

    /// The reason is capped so a huge error body can't bloat the database. Only status,
    /// fail_reason and fail_count are written, so results an earlier step saved are kept.
    public func markFailed(id: Int64, reason: String) async throws {
        let cappedReason = String(reason.prefix(Screenshot.maxFailReasonLength))
        try await writer.write { db in
            try Self.update(id, in: db, [
                Column("status").set(to: Status.failed),
                Column("fail_reason").set(to: cappedReason),
                // Counted in SQL, so it stays right however many times the screenshot failed before.
                Column("fail_count") += 1,
            ])
        }
    }

    /// After this many failures a screenshot stays failed, so a corrupt file isn't retried forever.
    public static let maxFailures = 3

    /// Puts failed screenshots back to pending so the queue tries them again, and returns how many.
    /// Screenshots that failed `maxFailures` times are left alone. Reset ones start clean: earlier
    /// results, the embedding and the keyword row are removed, so a retry never mixes old and new data.
    public func resetFailed() async throws -> Int {
        try await writer.write { db in
            let ids = try Int64.fetchAll(db, Screenshot
                .select(Column("id"))
                .filter(Column("status") == Status.failed && Column("fail_count") < Self.maxFailures))
            if ids.isEmpty { return 0 }

            try db.execute(literal: "DELETE FROM embeddings WHERE screenshot_id IN \(ids)")
            try db.execute(literal: "DELETE FROM screenshots_fts WHERE rowid IN \(ids)")
            return try Screenshot.filter(keys: ids).updateAll(db, [
                Column("status").set(to: Status.pending),
                Column("fail_reason").set(to: nil),
                Column("ocr_text").set(to: nil),
                Column("description").set(to: nil),
                Column("category").set(to: nil),
                Column("language").set(to: nil),
                Column("labels").set(to: nil),
                Column("entities").set(to: nil),
                Column("describer_model").set(to: nil),
                Column("indexed_at").set(to: nil),
            ])
        }
    }

    public func progressCounts() async throws -> ProgressCounts {
        try await writer.read { db in
            let indexed = try Screenshot.filter(Column("status") == Status.indexed).fetchCount(db)
            let failed = try Screenshot.filter(Column("status") == Status.failed).fetchCount(db)
            let total = try Screenshot.fetchCount(db)
            return ProgressCounts(pending: total - indexed - failed, indexed: indexed, failed: failed)
        }
    }

    private static func update(_ id: Int64, in db: Database, _ assignments: [ColumnAssignment]) throws {
        let changed = try Screenshot.filter(key: id).updateAll(db, assignments)
        if changed == 0 {
            throw StoreError.screenshotNotFound(id)
        }
    }

    /// The same JSON text a Screenshot record writes for its array columns, so it decodes back.
    private static func json(_ strings: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(strings), as: UTF8.self)
    }

    /// Float32 values, little-endian, as the embeddings table expects.
    static func encodeVector(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeVector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            (0 ..< data.count / 4).map { index in
                let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }
}
