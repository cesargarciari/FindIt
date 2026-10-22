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

    @Test func upgradingFromV1GivesExistingRowsZeroFailures() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO screenshots (path, file_hash, created_at, status) VALUES ('/a.png', 'a', 0, 'failed')")
        }

        try AppDatabase.migrator.migrate(queue)

        let loaded = try queue.read { db in try Screenshot.fetchOne(db) }
        #expect(loaded?.failCount == 0)
        #expect(loaded?.status == .failed)
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
