import FindItCore
import Foundation

/// From eval tuning: keyword matches count a quarter as much as meaning matches, and stopwords are kept.
enum SearchDefaults {
    static let keywordWeight = 0.25
    static let removeStopwords = false
}

struct ResultItem: Identifiable {
    let id: Int64
    let path: String
    let description: String
    let foundBy: FoundBy
}

/// The indexed screenshots: keeps the index up to date in the background and searches it.
@Observable final class Library {
    private(set) var counts: ProgressCounts?
    /// Why indexing isn't progressing, when it isn't.
    private(set) var indexingNote: String?
    private(set) var results: [ResultItem] = []
    private(set) var meaningUnavailable = false
    private(set) var searchError: String?

    private let folder: URL
    private let client: OllamaClient
    private let store: ScreenshotStore
    private let queue: IndexQueue
    private let engine: SearchEngine
    private var loops: [Task<Void, Never>] = []

    static let rescanInterval = Duration.seconds(30)
    static let countsInterval = Duration.seconds(2)

    init(databaseURL: URL, folder: URL) throws {
        let db = try AppDatabase.open(atPath: databaseURL.path)
        let client = OllamaClient()
        let config = IndexConfig()
        self.folder = folder
        self.client = client
        store = ScreenshotStore(db)
        engine = SearchEngine(db: db, embedder: client, model: config.embedderModel)
        queue = IndexQueue(
            db: db, recognizer: OCRService(), describer: client, labeler: Labeler(), embedder: client, config: config
        )
    }

    /// Starts the background loops. They run for the life of the app, so holding self strongly is fine.
    func start() {
        loops.append(Task {
            try? await engine.reload()
            while !Task.isCancelled {
                await rescan()
                try? await Task.sleep(for: Self.rescanInterval)
            }
        })
        loops.append(Task {
            while !Task.isCancelled {
                await refreshCounts()
                try? await Task.sleep(for: Self.countsInterval)
            }
        })
    }

    func retryFailed() async {
        do {
            let reset = try await store.resetFailed()
            if reset == 0 {
                indexingNote = "Nothing to retry: the rest failed \(ScreenshotStore.maxFailures) times."
            }
            await refreshCounts()
            startIndexing()
        } catch {
            indexingNote = "Couldn't reset failed screenshots: \(error.localizedDescription)"
        }
    }

    func search(_ query: String) async {
        do {
            let found: [SearchResult]
            var unavailable = false
            do {
                found = try await engine.search(
                    query,
                    keywordWeight: SearchDefaults.keywordWeight,
                    removeStopwords: SearchDefaults.removeStopwords
                )
            } catch OllamaError.unreachable {
                // Ollama isn't running: keyword results are still useful, so show those.
                found = try await engine.search(query, mode: .keywordOnly, removeStopwords: SearchDefaults.removeStopwords)
                unavailable = true
            }
            let descriptions = try await store.descriptions(for: found.map(\.id))
            // A newer search replaced this one while it ran, so its results are out of date.
            guard !Task.isCancelled else { return }
            results = found.map {
                ResultItem(id: $0.id, path: $0.path, description: descriptions[$0.id] ?? "", foundBy: $0.foundBy)
            }
            meaningUnavailable = unavailable
            searchError = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = "Search failed: \(error)"
        }
    }

    private func rescan() async {
        do {
            let files = try await Self.imageFiles(in: folder)
            _ = try await queue.enqueue(files)
        } catch {
            indexingNote = "Couldn't read \(folder.lastPathComponent): \(error.localizedDescription)"
            return
        }
        startIndexing()
    }

    /// Starts a pass without waiting for it. If a pass is already going, run() returns at once
    /// and the running pass picks up the new work.
    private func startIndexing() {
        Task {
            // Without Ollama every step after OCR would fail, so wait for the next rescan instead.
            guard await client.isAvailable() else {
                indexingNote = "Ollama isn't running, so indexing is paused."
                return
            }
            indexingNote = nil
            do {
                try await queue.run()
                try await engine.reload()
            } catch {
                indexingNote = "Indexing stopped: \(error)"
            }
            await refreshCounts()
        }
    }

    private func refreshCounts() async {
        counts = try? await store.progressCounts()
    }

    /// Off the main actor, because listing a large folder takes a moment.
    @concurrent private nonisolated static func imageFiles(in folder: URL) async throws -> [URL] {
        try FolderScanner().imageFiles(in: folder)
    }
}
