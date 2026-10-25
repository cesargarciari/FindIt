import Testing
@testable import FindItCore

@Test func fusionRewardsAgreement() {
    #expect(reciprocalRankFusion([[1, 2, 3, 4], [3, 1, 5, 2]]) == [1, 3, 2, 5, 4])
}

@Test func fusionBreaksTiesBySmallerID() {
    #expect(reciprocalRankFusion([[1, 2], [2, 1]]) == [1, 2])
}

@Test func fusionOfOneListKeepsItsOrder() {
    #expect(reciprocalRankFusion([[7, 3, 9]]) == [7, 3, 9])
}

@Test func fusionOfNothingIsEmpty() {
    #expect(reciprocalRankFusion([]).isEmpty)
}

@Test func fusionWithEqualWeightsMatchesNoWeights() {
    let lists: [[Int64]] = [[1, 2, 3, 4], [3, 1, 5, 2]]
    #expect(reciprocalRankFusion(lists, weights: [1, 1]) == reciprocalRankFusion(lists))
}

@Test func fusionWeightFavoursTheHeavierList() {
    // Unweighted, 1 and 2 tie and 1 wins on id; doubling the second list puts its top first.
    #expect(reciprocalRankFusion([[1, 2], [2, 1]]) == [1, 2])
    #expect(reciprocalRankFusion([[1, 2], [2, 1]], weights: [1, 2]) == [2, 1])
}

@Test func fusionWithZeroWeightKeepsOtherListOrder() {
    // A zero-weight list adds nothing, so the other list decides the order.
    #expect(reciprocalRankFusion([[5, 6], [6, 5]], weights: [0, 1]) == [6, 5])
}
