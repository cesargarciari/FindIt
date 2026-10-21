import Testing
@testable import FindItCore

private let ranked = ["A", "C", "B", "E", "D"]

@Test func recallFindsItemInsideTopK() {
    #expect(hitAtK(ranked, relevant: ["E"], k: 5) == 1.0)
}

@Test func recallMissesItemOutsideTopK() {
    #expect(hitAtK(ranked, relevant: ["E"], k: 3) == 0.0)
}

@Test func recallIsZeroForEmptyResults() {
    #expect(hitAtK([], relevant: ["A"], k: 5) == 0.0)
}

@Test func reciprocalRankUsesFirstRelevantHit() {
    #expect(reciprocalRank(ranked, relevant: ["C", "D"]) == 0.5)
}

@Test func reciprocalRankOfThirdPlace() {
    #expect(abs(reciprocalRank(ranked, relevant: ["B"]) - 1.0 / 3.0) < 1e-9)
}

@Test func reciprocalRankIsZeroWhenMissing() {
    #expect(reciprocalRank(ranked, relevant: ["Z"]) == 0.0)
}

@Test func recallCountsShareOfRelevantFound() {
    #expect(recallAtK(["A", "B", "C", "D"], relevant: ["A", "D"], k: 3) == 0.5)
}

@Test func recallIsFullWhenAllRelevantFound() {
    #expect(recallAtK(["A", "B", "C", "D"], relevant: ["A", "D"], k: 4) == 1.0)
}
