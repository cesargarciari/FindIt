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
