import Testing
@testable import FindItCore

@Test func normalizeScalesToUnitLength() {
    let v = normalize([3, 4])
    #expect(abs(v[0] - 0.6) < 1e-6)
    #expect(abs(v[1] - 0.8) < 1e-6)
}

@Test func unitVectorDottedWithItselfIsOne() {
    let v = normalize([1, 2, 3])
    #expect(abs(dot(v, v) - 1) < 1e-6)
}

@Test func perpendicularVectorsHaveZeroDot() {
    #expect(dot([1, 0], [0, 1]) == 0)
}

@Test func normalizingZeroVectorAvoidsNaN() {
    #expect(normalize([0, 0]) == [0, 0])
}
