import Foundation
import Testing
@testable import FindItCore

struct VisionTests {
    @Test func ocrReadsDrawnText() async throws {
        let text = try await withTemporaryDirectory { folder in
            let url = folder.appending(path: "text.png")
            try TestImages.write(try TestImages.text("Hola FindIt 2026"), to: url)
            return try await OCRService().recognizeText(at: url)
        }

        // All three words, so a misread "FindIt" can be told apart from OCR not working at all.
        #expect(text.contains("Hola"))
        #expect(text.contains("FindIt"))
        #expect(text.contains("2026"))
    }

    @Test func labelerRespectsMaxLabels() async throws {
        let labels = try await withTemporaryDirectory { folder in
            let url = folder.appending(path: "text.png")
            try TestImages.write(try TestImages.text("Hola FindIt 2026"), to: url)
            // Confidence 0 keeps every label, so only maxLabels limits the count.
            return try await Labeler().labels(forImageAt: url, minimumConfidence: 0, maxLabels: 3)
        }

        #expect(labels.count == 3)
    }
}
