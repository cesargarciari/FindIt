
func reciprocalRankFusion(_ lists: [[Int64]], k: Double = 60, weights: [Double]? = nil) -> [Int64] {
    if let weights {
        precondition(weights.count == lists.count, "one weight per list")
    }
    var scores: [Int64: Double] = [:]

    for (listIndex, list) in lists.enumerated() {
        let weight = weights?[listIndex] ?? 1.0
        for (index, document) in list.enumerated() {
            let rank = Double(index + 1)
            scores[document, default: 0.0] += weight / (k + rank)
        }
    }

    return scores.sorted { a, b in
    a.value != b.value ? a.value > b.value : a.key < b.key
    }.map { $0.key }
}
