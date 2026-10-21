import Testing
@testable import FindItCore

private let ranked = ["A", "C", "B", "E", "D"]

@Test func recallFindsItemInsideTopK() {
    #expect(recallAtK(ranked, relevant: ["E"], k: 5) == 1.0)
}

@Test func recallMissesItemOutsideTopK() {
    #expect(recallAtK(ranked, relevant: ["E"], k: 3) == 0.0)
}

@Test func recallIsZeroForEmptyResults() {
    #expect(recallAtK([], relevant: ["A"], k: 5) == 0.0)
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
