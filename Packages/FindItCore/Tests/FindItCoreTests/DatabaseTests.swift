import Foundation
import GRDB
import Testing
@testable import FindItCore

struct DatabaseTests {
    @Test func insertAndReadBackScreenshot() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)

        // Whole seconds, so the date survives SQLite's millisecond storage exactly.
        var screenshot = Screenshot(
            path: "/tmp/shot.png",
            fileHash: "abc123",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            labels: ["receipt", "text"],
            entities: #"{"people":[]}"#
        )
        try queue.write { db in try screenshot.insert(db) }

        let id = try #require(screenshot.id)
        let loaded = try queue.read { db in try Screenshot.fetchOne(db, key: id) }
        #expect(loaded == screenshot)
        #expect(loaded?.status == .pending)
    }

    // macOS can return NFD filenames, but SQLite compares text byte by byte, and the golden set is NFC.
    @Test func pathIsStoredAsNFC() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let nfd = "/tmp/cafe\u{301}.png"
        let nfc = "/tmp/caf\u{E9}.png"

        var inserted = Screenshot(path: nfd, fileHash: "a", createdAt: Date(timeIntervalSince1970: 0))
        var renamed = Screenshot(path: "/tmp/old.png", fileHash: "b", createdAt: Date(timeIntervalSince1970: 0))
        renamed.path = nfd

        let matches = try queue.write { db in
            try inserted.insert(db)
            try renamed.insert(db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE path = ?", arguments: [nfc])
        }
        #expect(matches == 2)
    }

    @Test func pathReadFromDatabaseIsNFC() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)

        let loaded = try queue.write { db in
            try db.execute(
                sql: "INSERT INTO screenshots (path, file_hash, created_at, status) VALUES (?, 'a', 0, 'pending')",
                arguments: ["/tmp/cafe\u{301}.png"]
            )
            return try Screenshot.fetchOne(db)
        }
        // Swift's == ignores NFC vs NFD, so compare the bytes.
        #expect(loaded.map { Array($0.path.utf8) } == Array("/tmp/caf\u{E9}.png".utf8))
    }

    @Test func markFailedOnlyWritesStatusAndReason() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        var screenshot = Screenshot(path: "/tmp/shot.png", fileHash: "a", createdAt: Date(timeIntervalSince1970: 0))

        let loaded = try queue.write { db in
            try screenshot.insert(db)
            // Another writer saves OCR text after this copy was read.
            try db.execute(sql: "UPDATE screenshots SET ocr_text = 'hola' WHERE id = ?", arguments: [screenshot.id])
            try screenshot.markFailed(reason: "boom", in: db)
            return try Screenshot.fetchOne(db, key: screenshot.id)
        }
        #expect(loaded?.ocrText == "hola")
        #expect(loaded?.status == .failed)
    }

    @Test func markFailedLeavesValueUnchangedWhenSaveFails() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        var neverInserted = Screenshot(path: "/tmp/shot.png", fileHash: "a", createdAt: Date(timeIntervalSince1970: 0))

        try queue.write { db in
            #expect(throws: (any Error).self) { try neverInserted.markFailed(reason: "boom", in: db) }
        }
        #expect(neverInserted.status == .pending)
        #expect(neverInserted.failReason == nil)
    }

    @Test func markFailedSavesStatusAndCapsReason() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        var screenshot = Screenshot(path: "/tmp/shot.png", fileHash: "a", createdAt: Date(timeIntervalSince1970: 0))

        let loaded = try queue.write { db in
            try screenshot.insert(db)
            try screenshot.markFailed(reason: String(repeating: "é", count: 5000), in: db)
            return try Screenshot.fetchOne(db, key: screenshot.id)
        }
        #expect(loaded?.status == .failed)
        #expect(loaded?.failReason?.count == 1000)
        #expect(loaded == screenshot)
    }

    @Test func ftsTableUsesDiacriticRemovingTokenizer() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)

        let (sql, matches) = try queue.write { db in
            try db.execute(sql: "INSERT INTO screenshots_fts (rowid, searchable_text) VALUES (1, 'Café de la canción')")
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'screenshots_fts'")
            let matches = try Int64.fetchAll(db, sql: "SELECT rowid FROM screenshots_fts WHERE screenshots_fts MATCH 'cafe cancion'")
            return (sql, matches)
        }
        // GRDB quotes each tokenizer argument, so this is "unicode61 remove_diacritics 2" in SQL form.
        #expect(sql?.contains("'''unicode61'' ''remove_diacritics'' ''2'''") == true)
        #expect(matches == [1])
    }
}
