import GRDB

/// Screenshot ids whose text matches any word of `query`, best bm25 first.
func keywordSearch(_ query: String, db: DatabaseQueue, limit: Int) async throws -> [Int64] {
    // GRDB quotes each token, so input like `don't AND (` can't break the FTS5 syntax.
    guard let pattern = FTS5Pattern(matchingAnyTokenIn: query) else {
        return []
    }
    return try await db.read { db in
        // bm25 is lower for better matches, hence ascending.
        try Int64.fetchAll(db, sql: """
            SELECT rowid FROM screenshots_fts
            WHERE screenshots_fts MATCH ?
            ORDER BY bm25(screenshots_fts)
            LIMIT ?
            """, arguments: [pattern, limit])
    }
}
