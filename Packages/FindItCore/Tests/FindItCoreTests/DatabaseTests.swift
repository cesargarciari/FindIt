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
