/// Every stored vector held in memory. Brute force is fast enough for a personal screenshot folder.
struct VectorIndex: Sendable {
    private let vectors: [Int64: [Float]]

    init(vectors: [Int64: [Float]]) {
        self.vectors = vectors
    }

    var isEmpty: Bool { vectors.isEmpty }

    /// Ids by dot product with `query`, highest first, ties to the smaller id. Expects a normalized query.
    func search(_ query: [Float], limit: Int) -> [Int64] {
        let scored = vectors
            // dot() traps on mismatched lengths, so one odd stored vector must not crash search.
            .filter { $0.value.count == query.count }
            .map { (id: $0.key, score: dot($0.value, query)) }
        return scored
            .sorted { a, b in a.score != b.score ? a.score > b.score : a.id < b.id }
            .prefix(max(limit, 0))
            .map(\.id)
    }
}
