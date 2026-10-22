import Testing
@testable import FindItCore

@Test func vectorSearchOrdersByDotProductHighestFirst() {
    let index = VectorIndex(vectors: [1: [1, 0], 2: [0.6, 0.8], 3: [0, 1]])

    #expect(index.search([0, 1], limit: 10) == [3, 2, 1])
}

@Test func vectorSearchBreaksTiesBySmallerID() {
    let index = VectorIndex(vectors: [9: [1, 0], 4: [1, 0], 7: [1, 0]])

    #expect(index.search([1, 0], limit: 10) == [4, 7, 9])
}

@Test func vectorSearchReturnsOnlyTheTopLimit() {
    let index = VectorIndex(vectors: [1: [1, 0], 2: [0.6, 0.8], 3: [0, 1]])

    #expect(index.search([1, 0], limit: 2) == [1, 2])
}

@Test func vectorSearchOfEmptyIndexIsEmpty() {
    #expect(VectorIndex(vectors: [:]).search([1, 0], limit: 10).isEmpty)
}

@Test func vectorSearchSkipsVectorsOfOtherLengths() {
    let index = VectorIndex(vectors: [1: [1, 0], 2: [1, 0, 0]])

    #expect(index.search([1, 0], limit: 10) == [1])
}
