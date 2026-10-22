import Foundation
import GRDB

/// The step a derived database goes back to.
public enum DeriveResetTarget: String, CaseIterable, Sendable {
    /// Keeps OCR and descriptions, so only embedding is redone. For comparing embedders.
    /// Screenshots that failed after describing get another try.
    case described
    /// Keeps only OCR, so describing and embedding are redone. For comparing describers.
    /// Described screenshots, and ones that failed after OCR, start again from ocr_done too.
    case ocrDone = "ocr_done"
}

public enum DeriveError: Error, Equatable, Sendable {
    case sourceMissing(String)
    case targetExists(String)
}

public struct DeriveResult: Equatable, Sendable {
    /// Indexed screenshots set back to the reset status.
    public let resetIndexed: Int
    /// Described screenshots set back to ocr_done. Always 0 when resetting to described.
    public let resetDescribed: Int
    /// Failed screenshots given another try: those with a description when resetting to described,
    /// those with OCR text when resetting to ocr_done.
    public let resetFailed: Int
}

/// Copies an eval database and rolls it back to an earlier step, so another model can be
/// compared without redoing the slow steps before it. The source is never changed.
public func deriveDatabase(from source: URL, to target: URL, resetTo: DeriveResetTarget) throws -> DeriveResult {
    let files = FileManager.default
    guard files.fileExists(atPath: source.path) else { throw DeriveError.sourceMissing(source.path) }
    // Never overwrite, because a finished eval database can take hours to rebuild.
    guard !files.fileExists(atPath: target.path) else { throw DeriveError.targetExists(target.path) }

    do {
        var readOnly = Configuration()
        readOnly.readonly = true
        let sourceQueue = try DatabaseQueue(path: source.path, configuration: readOnly)
        let targetQueue = try DatabaseQueue(path: target.path)
        // SQLite's backup copies a consistent snapshot, which a plain file copy can't promise.
        try sourceQueue.backup(to: targetQueue)
        try AppDatabase.migrator.migrate(targetQueue)
        return try targetQueue.write { db in try reset(db, to: resetTo) }
    } catch {
        // A half-made copy would make the next attempt fail with targetExists.
        try? files.removeItem(at: target)
        throw error
    }
}

private func reset(_ db: Database, to target: DeriveResetTarget) throws -> DeriveResult {
    try db.execute(sql: "DELETE FROM embeddings")
    try db.execute(sql: "DELETE FROM screenshots_fts")

    let indexed = Screenshot.filter(Column("status") == Status.indexed)
    let failed = Screenshot.filter(Column("status") == Status.failed)
    // Every retried row starts with a clean failure count, so resetFailed's cap applies to the new model only.
    let retry: [ColumnAssignment] = [
        Column("fail_reason").set(to: nil),
        Column("fail_count").set(to: 0),
        Column("indexed_at").set(to: nil),
    ]
    switch target {
    case .described:
        let backToDescribed = retry + [Column("status").set(to: Status.described)]
        let count = try indexed.updateAll(db, backToDescribed)
        // A failure after describing happened at embedding, maybe the old embedder's fault.
        let failedCount = try failed
            .filter(Column("description") != nil)
            .updateAll(db, backToDescribed + [Column("labels").set(to: nil)])
        return DeriveResult(resetIndexed: count, resetDescribed: 0, resetFailed: failedCount)

    case .ocrDone:
        let backToOCRDone = retry + [
            Column("status").set(to: Status.ocrDone),
            Column("description").set(to: nil),
            Column("category").set(to: nil),
            Column("language").set(to: nil),
            Column("entities").set(to: nil),
            Column("labels").set(to: nil),
            Column("describer_model").set(to: nil),
        ]
        let count = try indexed.updateAll(db, backToOCRDone)
        // Described by the old model but not yet embedded, so it must be described again too.
        let describedCount = try Screenshot
            .filter(Column("status") == Status.described)
            .updateAll(db, backToOCRDone)
        // A failure after OCR may have been the describer's fault, so the new one gets a try.
        let failedCount = try failed
            .filter(Column("ocr_text") != nil)
            .updateAll(db, backToOCRDone)
        return DeriveResult(resetIndexed: count, resetDescribed: describedCount, resetFailed: failedCount)
    }
}
