import Foundation

// One protocol per pipeline step, so IndexQueue can be tested with fakes instead of Vision and Ollama.

public protocol TextRecognizing: Sendable {
    func recognizeText(at url: URL) async throws -> String
}

public protocol ImageLabeling: Sendable {
    func labels(forImageAt url: URL) async throws -> [String]
}

public protocol ImageDescribing: Sendable {
    func describe(imageJPEG: Data, prompt: String, schemaJSON: String, model: String) async throws -> String
}

public protocol TextEmbedding: Sendable {
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}

extension OCRService: TextRecognizing {}

extension Labeler: ImageLabeling {
    // The protocol has no tuning knobs, so the queue gets Labeler's defaults.
    public func labels(forImageAt url: URL) async throws -> [String] {
        try await labels(forImageAt: url, minimumConfidence: Self.defaultMinimumConfidence, maxLabels: Self.defaultMaxLabels)
    }
}

extension OllamaClient: ImageDescribing {
    public func describe(imageJPEG: Data, prompt: String, schemaJSON: String, model: String) async throws -> String {
        try await describe(
            imageJPEG: imageJPEG,
            prompt: prompt,
            schemaJSON: schemaJSON,
            model: model,
            temperature: Self.defaultTemperature,
            think: Self.defaultThink
        )
    }
}

extension OllamaClient: TextEmbedding {}
