
func reciprocalRankFusion(_ lists: [[Int64]], k: Double = 60) -> [Int64] {
    var scores: [Int64: Double] = [:]

    for list in lists {
        for (index, document) in list.enumerated() {
            let rank = Double(index + 1)
            scores[document, default: 0.0] += 1.0 / (k + rank)
        }
    }

    return scores.sorted { a, b in
    a.value != b.value ? a.value > b.value : a.key < b.key
    }.map { $0.key }
}
