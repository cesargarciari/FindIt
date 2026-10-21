import Foundation
import Vision

/// Adds Vision's image classification labels, used when a screenshot has little text.
public struct Labeler: Sendable {
    public init() {}

    /// Returns up to `maxLabels` identifiers, most confident first.
    public func labels(forImageAt url: URL, minimumConfidence: Float = 0.3, maxLabels: Int = 5) async throws -> [String] {
        let observations = try await ClassifyImageRequest().perform(on: url)
        return observations
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            // prefix traps on a negative count.
            .prefix(max(0, maxLabels))
            .map(\.identifier)
    }
}
