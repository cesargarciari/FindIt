import Foundation
import GRDB

public enum SearchMode: Sendable {
    case fused
    case keywordOnly
    case vectorOnly
}

/// Which search found a result, so the UI can show why it matched.
public enum FoundBy: Equatable, Sendable {
    case keyword
    case meaning
    case both
}

public struct SearchResult: Equatable, Sendable {
    public let id: Int64
    public let path: String
    public let foundBy: FoundBy
}

public enum SearchError: Error, Equatable, Sendable {
    case emptyEmbedding
}

/// Keyword and vector search merged with reciprocal rank fusion.
public actor SearchEngine {
    /// How many ids each search hands to fusion.
    static let candidateLimit = 50

    private let db: DatabaseQueue
    private let store: ScreenshotStore
    private let embedder: any TextEmbedding
    private let model: String
    // Empty until reload(), so search before it still gives keyword results.
    private var vectorIndex = VectorIndex(vectors: [:])

    public init(db: DatabaseQueue, embedder: any TextEmbedding, model: String) {
        self.db = db
        self.store = ScreenshotStore(db)
        self.embedder = embedder
        self.model = model
    }

    /// Reads every stored vector again. Call after indexing so new screenshots show up.
    public func reload() async throws {
        vectorIndex = VectorIndex(vectors: try await store.allEmbeddings(model: model))
    }

    public func search(_ query: String, mode: SearchMode = .fused, limit: Int = 20) async throws -> [SearchResult] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }

        let keywordIds = mode == .vectorOnly ? [] : try await keywordSearch(query, db: db, limit: Self.candidateLimit)
        let vectorIds = mode == .keywordOnly ? [] : try await vectorSearch(query)

        let fused = reciprocalRankFusion([keywordIds, vectorIds]).prefix(max(limit, 0))
        let paths = try await store.paths(for: Array(fused))
        let byKeyword = Set(keywordIds)
        let byMeaning = Set(vectorIds)

        // A screenshot deleted since it was found has no path, so it is left out.
        return fused.compactMap { id in
            guard let path = paths[id] else { return nil }
            let foundBy: FoundBy = byKeyword.contains(id) && byMeaning.contains(id) ? .both
                : byKeyword.contains(id) ? .keyword : .meaning
            return SearchResult(id: id, path: path, foundBy: foundBy)
        }
    }

    private func vectorSearch(_ query: String) async throws -> [Int64] {
        // Nothing to compare against, so skip the Ollama call.
        if vectorIndex.isEmpty { return [] }
        let vectors = try await embedder.embed([queryPrefix(for: model) + query], model: model)
        guard let first = vectors.first, !first.isEmpty else { throw SearchError.emptyEmbedding }
        return vectorIndex.search(normalize(first), limit: Self.candidateLimit)
    }
}
