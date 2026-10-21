public func recallAtK(_ results: [String], relevant: Set<String>, k: Int) -> Double {
    let topResults = results.prefix(k)

    let foundRelevant = topResults.contains { item in
        relevant.contains(item)
    }

    return foundRelevant ? 1.0 : 0.0
}

public func reciprocalRank(_ results: [String], relevant: Set<String>) -> Double{
    let index = results.firstIndex { item in
    relevant.contains(item)
    }

    if let index = index {
        return 1.0 / Double(index + 1)
    } else {
        return 0.0
    }

}