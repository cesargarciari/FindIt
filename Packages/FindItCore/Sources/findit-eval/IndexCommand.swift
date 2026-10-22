import ArgumentParser
import FindItCore
import Foundation

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Index the eval corpus into its own database.",
        discussion: "Running it again on the same database resumes where it stopped."
    )

    @Option(help: "Folder of screenshots, relative to the current directory.")
    var corpus = "eval/corpus"

    @Option(help: "Eval database file. Never the app's database.")
    var db: String

    @Option(help: "Ollama vision model for descriptions.")
    var describer = "qwen3-vl:8b"

    @Option(help: "Ollama embedding model.")
    var embedder = "bge-m3"

    @Option(help: "Longest side in pixels before describing; 0 sends full size.")
    var maxDimension = 1024

    @Option(help: "Only enqueue the first N files by name, for smoke tests. Unfinished screenshots already in the database are still processed.")
    var limit: Int?

    func validate() throws {
        guard maxDimension >= 0 else { throw ValidationError("--max-dimension must be 0 or more.") }
        if let limit, limit <= 0 { throw ValidationError("--limit must be at least 1.") }
    }

    func run() async throws {
        let client = OllamaClient()
        try await checkModels(client)

        let database = try AppDatabase.open(atPath: db)
        let store = ScreenshotStore(database)
        var config = IndexConfig()
        config.describerModel = describer
        config.embedderModel = embedder
        config.maxDimension = maxDimension == 0 ? nil : maxDimension
        // The search_document: prefix for nomic-embed-text comes from documentPrefix(for:) inside the queue.
        let queue = IndexQueue(db: database, recognizer: OCRService(), describer: client, labeler: Labeler(), embedder: client, config: config)

        var files = try FolderScanner().imageFiles(in: URL(fileURLWithPath: corpus))
        if let limit { files = Array(files.prefix(limit)) }
        let enqueued = try await queue.enqueue(files)
        print("Found \(files.count) images: \(enqueued.added) new, \(files.count - enqueued.added - enqueued.skipped.count) already in the database.")
        for path in enqueued.skipped {
            print("Skipped unreadable file: \(path)")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let before = try await store.progressCounts()
        // Screenshots finished in earlier runs don't count towards this run's speed.
        let finishedBefore = before.indexed + before.failed

        let reporter = Task {
            var nextReport = 10
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let counts = try? await store.progressCounts() else { continue }
                let doneThisRun = counts.indexed + counts.failed - finishedBefore
                if doneThisRun >= nextReport {
                    printProgress(counts, doneThisRun: doneThisRun, elapsed: start.duration(to: clock.now))
                    nextReport = (doneThisRun / 10 + 1) * 10
                }
            }
        }
        defer { reporter.cancel() }
        try await queue.run()
        reporter.cancel()
        // Waited for, so a progress line read just before the cancel can't print after the summary.
        await reporter.value

        let elapsed = start.duration(to: clock.now)
        let counts = try await store.progressCounts()
        let doneThisRun = counts.indexed + counts.failed - finishedBefore
        print("")
        print("Indexed: \(counts.indexed)")
        print("Failed:  \(counts.failed)")
        for (reason, count) in try await store.failureReasons().sorted(by: { $0.value > $1.value }) {
            print("  \(count) × \(reason)")
        }
        if counts.pending > 0 {
            print("Still unfinished: \(counts.pending). Run the same command again to resume.")
        }
        print("Total time: \(format(elapsed))")
        print("Seconds per screenshot: \(perScreenshot(elapsed, doneThisRun))")
    }

    /// Exits with a clear message before any work, rather than failing every screenshot.
    private func checkModels(_ client: OllamaClient) async throws {
        guard await client.isAvailable() else {
            throw exitWithMessage("Ollama isn't reachable at \(client.baseURL.absoluteString). Start it with `ollama serve`.")
        }
        let installed = try await client.installedModels()
        for model in [describer, embedder] where !OllamaClient.isInstalled(model, in: installed) {
            throw exitWithMessage("Model \(model) isn't installed in Ollama. Run `ollama pull \(model)`.")
        }
    }

    private func printProgress(_ counts: ProgressCounts, doneThisRun: Int, elapsed: Duration) {
        let total = counts.pending + counts.indexed + counts.failed
        let finished = counts.indexed + counts.failed
        print("\(finished)/\(total) finished, \(counts.failed) failed, \(format(elapsed)) elapsed, \(perScreenshot(elapsed, doneThisRun)) s per screenshot")
    }
}

func exitWithMessage(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    return ExitCode.failure
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func format(_ duration: Duration) -> String {
    let total = Int(seconds(duration))
    return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

private func perScreenshot(_ elapsed: Duration, _ count: Int) -> String {
    count > 0 ? String(format: "%.1f", seconds(elapsed) / Double(count)) : "-"
}
