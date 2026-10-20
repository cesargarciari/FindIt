import Foundation
import GRDB

public enum AppDatabase {
    /// Opens (or creates) the SQLite file at `path` and brings its schema up to date.
    public static func open(atPath path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try migrator.migrate(queue)
        return queue
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "screenshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull()
                // Unique so the same image is never indexed twice.
                t.column("file_hash", .text).notNull().unique()
                t.column("created_at", .datetime).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("fail_reason", .text)
                t.column("ocr_text", .text)
                t.column("description", .text)
                t.column("category", .text)
                t.column("language", .text)
                t.column("labels", .text)
                t.column("entities", .text)
                t.column("describer_model", .text)
                t.column("indexed_at", .datetime)
            }

            
            // remove_diacritics 2 lets "cafe" match "café" for spanish
            try db.create(virtualTable: "screenshots_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("searchable_text")
            }

            try db.create(table: "embeddings") { t in
                t.column("screenshot_id", .integer)
                    .notNull()
                    .references("screenshots", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("dims", .integer).notNull()
                // Float32 values, little-endian.
                t.column("vector", .blob).notNull()
                // One vector per model, so switching embedders doesn't overwrite old vectors
                t.primaryKey(["screenshot_id", "model"])
            }
        }

        return migrator
    }
}
