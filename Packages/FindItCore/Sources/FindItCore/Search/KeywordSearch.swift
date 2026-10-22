import GRDB

/// Screenshot ids whose text matches any word of `query`, best bm25 first.
func keywordSearch(_ query: String, db: DatabaseQueue, limit: Int) async throws -> [Int64] {
    // Safe for any input: GRDB's ascii tokenizer drops punctuation and lowercases AND, OR and NOT,
    // so FTS5 doesn't read them as operators, and an invalid pattern gives nil instead of an error.
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
