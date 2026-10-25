import ArgumentParser
import FindItCore
import Foundation

enum EvalMode: String, CaseIterable, ExpressibleByArgument {
    case fused
    case keyword
    case vector

    var searchMode: SearchMode {
        switch self {
        case .fused: .fused
        case .keyword: .keywordOnly
        case .vector: .vectorOnly
        }
    }
}

extension EvalSplit: ExpressibleByArgument {}

struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Score search against the golden set and save the results.",
        discussion: "Writes eval/results/<name>/per_query.jsonl and summary.json. Query text is never printed or saved."
    )

    @Option(help: "Golden set JSONL file.")
    var golden: String

    @Option(help: "Folder of screenshots the golden set refers to.")
    var corpus: String

    @Option(help: "Indexed eval database. Never the app's database.")
    var db: String

    @Option(help: "Embedding model the database was indexed with.")
    var embedder = "bge-m3"

    @Option(help: "fused, keyword or vector.")
    var mode: EvalMode = .fused

    @Option(help: "How much the keyword list counts in fused mode; the vector list counts 1.")
    var keywordWeight = 1.0

    @Flag(help: "Drop common English and Spanish words from keyword queries.")
    var stopwords = false

    @Option(help: "all, dev (odd query ids) or test (even query ids).")
    var split: EvalSplit = .all

    @Option(help: "Run name; results go to eval/results/<name>.")
    var name: String

    func validate() throws {
        // A negative weight would push keyword matches down instead of up.
        guard keywordWeight.isFinite, keywordWeight >= 0 else {
            throw ValidationError("--keyword-weight must be a number of 0 or more.")
        }
        // The name becomes one folder, so it can't climb out of eval/results.
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw ValidationError("--name must be a plain folder name.")
        }
    }

    func run() async throws {
        let results = URL(fileURLWithPath: "eval/results").appending(path: name)
        // Checked before the slow part too, so a typo doesn't cost a whole run.
        guard !FileManager.default.fileExists(atPath: results.path) else {
            throw exitWithMessage("\(results.path) already exists. Pick a new --name; results are never overwritten.")
        }
        // Opening a missing file would create an empty database and score every query 0.
        guard FileManager.default.fileExists(atPath: db) else {
            throw exitWithMessage("\(db) doesn't exist. Build it first with `index --db \(db)`.")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: corpus, isDirectory: &isFolder), isFolder.boolValue else {
            throw exitWithMessage("\(corpus) isn't a folder.")
        }

        let client = OllamaClient()
        if mode != .keyword {
            guard await client.isAvailable() else {
                throw exitWithMessage("Ollama isn't reachable at \(client.baseURL.absoluteString). Start it, or use --mode keyword.")
            }
            guard OllamaClient.isInstalled(embedder, in: try await client.installedModels()) else {
                throw exitWithMessage("Model \(embedder) isn't installed in Ollama. Run `ollama pull \(embedder)`.")
            }
        }

        let queries: [GoldenQuery]
        do {
            queries = try loadGolden(at: URL(fileURLWithPath: golden))
        } catch GoldenSetError.malformedLine(let line, _) {
            // Only the line number: the line holds query text.
            throw exitWithMessage("\(golden) line \(line) isn't a valid golden query.")
        }

        let report: EvalReport
        do {
            report = try await runEval(
                golden: queries,
                corpus: URL(fileURLWithPath: corpus),
                db: try AppDatabase.open(atPath: db),
                embedder: client,
                model: embedder,
                mode: mode.searchMode,
                keywordWeight: keywordWeight,
                removeStopwords: stopwords,
                split: split
            )
        } catch EvalError.noVectors(let model) {
            throw exitWithMessage("\(db) has no vectors for \(model). Pass the --embedder it was indexed with, or use --mode keyword.")
        } catch EvalError.unnumberedQuery(let id) {
            throw exitWithMessage("Query \(id) doesn't end in a digit, so --split \(split.rawValue) can't place it. Use --split all.")
        }

        printCheck(report)
        printConfig(report.summary.config)
        printTable(report.summary)
        try writeEvalResults(report, to: results)
        print("\nSaved \(results.path)")
    }

    private func printCheck(_ report: EvalReport) {
        let check = report.check
        for (label, files) in [
            ("Golden files missing from the corpus", check.missingFromCorpus),
            ("Golden files that failed indexing", check.failed),
            ("Golden files not indexed yet", check.unfinished),
        ] where !files.isEmpty {
            print("\(label) (\(files.count)): \(files.joined(separator: ", "))")
        }
        if !report.unscored.isEmpty {
            print("Not scored, no relevant file in the corpus (\(report.unscored.count)): \(report.unscored.joined(separator: ", "))")
        }
    }

    private func printConfig(_ config: EvalConfig) {
        print("")
        print("embedder: \(config.embedder)  mode: \(config.mode.rawValue)  keyword weight: \(config.keywordWeight)  "
            + "stopwords: \(config.stopwords ? "removed" : "kept")  split: \(config.split.rawValue)")
    }

    private func printTable(_ summary: EvalSummary) {
        print("")
        print(row("group", "n", "hit@5", "recall@5", "MRR@20"))
        print(row("all", summary.overall))
        for (title, groups) in [("type", summary.byType), ("lang", summary.byLang), ("type/lang", summary.byTypeAndLang)] {
            print("-- by \(title)")
            for key in groups.keys.sorted() {
                if let metrics = groups[key] { print(row(key, metrics)) }
            }
        }
        print(String(format: "\nQuery time: median %.1f ms, p95 %.1f ms", summary.medianQueryMs, summary.p95QueryMs))
    }

    private func row(_ group: String, _ metrics: MetricSummary) -> String {
        let recall = metrics.recallAt5.map { String(format: "%.3f (%d)", $0, metrics.multiQueries) } ?? "-"
        return row(group, String(metrics.queries), String(format: "%.3f", metrics.hitAt5), recall, String(format: "%.3f", metrics.mrr))
    }

    private func row(_ columns: String...) -> String {
        let widths = [18, 5, 7, 12, 7]
        return zip(columns, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: " ")
    }
}
