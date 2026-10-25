import Foundation
import GRDB

/// Screenshot ids whose text matches any word of `query`, best bm25 first.

func keywordSearch(_ query: String, db: DatabaseQueue, limit: Int, removeStopwords: Bool = false) async throws -> [Int64] {
    let text = removeStopwords ? withoutStopwords(query) : query
    // Safe for any input: GRDB's ascii tokenizer drops punctuation and lowercases AND, OR and NOT,
    // so FTS5 doesn't read them as operators, and an invalid pattern gives nil instead of an error.
    guard let pattern = FTS5Pattern(matchingAnyTokenIn: text) else {
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

func withoutStopwords(_ query: String) -> String {
    query
        .split { !$0.isLetter && !$0.isNumber }
        // Folded like the FTS tokenizer folds, so "Qué" and "que" are the same word.
        .filter { !stopwords.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        .joined(separator: " ")
}


private let stopwords: Set<String> = [
    // English
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "i", "in", "is", "it",
    "me", "my", "of", "on", "or", "that", "the", "this", "to", "was", "with",
    // Spanish
    "al", "con", "de", "del", "el", "en", "es", "esta", "la", "las", "lo", "los", "mi", "o",
    "para", "por", "que", "se", "su", "un", "una", "y",
]
