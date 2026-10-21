import Foundation

func normalize(_ v: [Float]) -> [Float] {
    let length = sqrt(
        v.map { value in value * value }
            .reduce(Float(0)) { sum, number in sum + number }
    )

    guard length > 0 else {
        return v
    }

    return v.map { value in value / length }
}

func dot(_ a: [Float], _ b: [Float]) -> Float{
    let result = zip(a, b).reduce(Float(0)) { sum, pair in
        sum + (pair.0 * pair.1)
    }

    return result
}
