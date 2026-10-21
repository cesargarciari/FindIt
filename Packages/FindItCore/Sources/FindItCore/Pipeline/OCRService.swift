import Foundation
import Vision

/// Reads text from an image with Vision, in English and Spanish.
public struct OCRService: Sendable {
    public init() {}

    /// Returns each recognized line, in the order Vision reports them, joined with newlines.
    public func recognizeText(at url: URL) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "es-ES")]

        let observations = try await request.perform(on: url)
        // No confidence filter: low-confidence text still helps keyword search.
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
