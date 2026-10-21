import Foundation

// Feeds both the FTS5 index and the embedding model. The description goes
// first because it is the cleanest text; OCR goes last because it is the noisiest.
func searchableText(ocr: String, description: String, labels: [String]) -> String {
    let labelText = labels
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")

    let parts = [description, labelText, ocr]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    return parts.joined(separator: "\n")
}
