import Foundation
import GRDB

/// Golden files that can't be found by search, reported before scoring so a low number isn't
/// mistaken for bad retrieval.
public struct CorpusCheck: Equatable, Sendable {
    /// Golden filenames with no file of exactly that name in the corpus.
    public let missingFromCorpus: [String]
    /// Golden filenames whose screenshot failed indexing.
    public let failed: [String]
    /// Golden filenames not indexed yet, including ones never enqueued.
    public let unfinished: [String]
}

/// One line of per_query.jsonl. Holds no query text, because the golden set is private.
public struct QueryResult: Codable, Equatable, Sendable {
    public let id: String
    /// Rank of the first relevant result within the top 20, from 1, or nil when none is there.
    public let firstHitRank: Int?
    /// Filenames of the top 5 results.
    public let top5: [String]
    /// Whether a relevant result is in the top 5.
    public let hit: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case firstHitRank = "first_hit_rank"
        case top5 = "top_5"
        case hit
    }
}

public struct MetricSummary: Codable, Equatable, Sendable {
    public let queries: Int
    public let hitAt5: Double
    /// How many of `queries` are multi queries, the only ones recall@5 covers.
    public let multiQueries: Int
    /// Nil when the group has no multi queries.
    public let recallAt5: Double?
    public let mrr: Double

    enum CodingKeys: String, CodingKey {
        case queries
        case hitAt5 = "hit_at_5"
        case multiQueries = "multi_queries"
        case recallAt5 = "recall_at_5"
        case mrr
    }
}

public enum EvalSplit: String, Codable, CaseIterable, Sendable {
    case all
    case dev
    case test

    func includes(_ query: GoldenQuery) throws -> Bool {
        if self == .all { return true }
        guard let last = query.id.last, last.isASCII, let digit = last.wholeNumberValue else {
            throw EvalError.unnumberedQuery(query.id)
        }
        return (digit % 2 == 1) == (self == .dev)
    }
}

/// The settings a run used, saved with its numbers so runs can be compared later.
public struct EvalConfig: Codable, Equatable, Sendable {
    public let embedder: String
    public let mode: SearchMode
    public let keywordWeight: Double
    public let stopwords: Bool
    public let split: EvalSplit

    enum CodingKeys: String, CodingKey {
        case embedder
        case mode
        case keywordWeight = "keyword_weight"
        case stopwords
        case split
    }
}

/// summary.json: the run's settings and numbers, no query text.
public struct EvalSummary: Codable, Equatable, Sendable {
    public let config: EvalConfig
    public let overall: MetricSummary
    public let byType: [String: MetricSummary]
    public let byLang: [String: MetricSummary]
    /// Keyed "type/lang".
    public let byTypeAndLang: [String: MetricSummary]
    public let medianQueryMs: Double
    public let p95QueryMs: Double
    /// Queries left out of scoring because none of their relevant files is in the corpus.
    public let unscoredQueries: Int
    public let missingFromCorpus: Int
    public let notIndexedFailed: Int
    public let notIndexedUnfinished: Int

    enum CodingKeys: String, CodingKey {
        case config
        case overall
        case byType = "by_type"
        case byLang = "by_lang"
        case byTypeAndLang = "by_type_and_lang"
        case medianQueryMs = "median_query_ms"
        case p95QueryMs = "p95_query_ms"
        case unscoredQueries = "unscored_queries"
        case missingFromCorpus = "missing_from_corpus"
        case notIndexedFailed = "not_indexed_failed"
        case notIndexedUnfinished = "not_indexed_unfinished"
    }
}

public struct EvalReport: Sendable {
    public let check: CorpusCheck
    /// Ids of queries that couldn't be scored, because none of their relevant files is in the corpus.
    public let unscored: [String]
    public let perQuery: [QueryResult]
    public let summary: EvalSummary
}

public enum EvalError: Error, Equatable, Sendable {
    case resultsExist(String)
    /// No indexed vectors for this model, so vector search would quietly find nothing.
    case noVectors(model: String)
    /// A query id with no last digit, so a dev or test split can't place it.
    case unnumberedQuery(String)
}

/// One scored query, kept apart from QueryResult so per_query.jsonl stays small.
private struct Scored {
    let type: String
    let lang: String
    let hitAt5: Double
    /// Nil for queries that aren't multi.
    let recallAt5: Double?
    let reciprocalRank: Double
}

/// Runs every golden query in `split` and scores it.
///
/// Results are matched by content: a result counts as relevant when its stored file hash equals
/// the hash of a golden file. So a byte-identical copy, which indexing stores only once, still counts.
public func runEval(
    golden: [GoldenQuery],
    corpus: URL,
    db: DatabaseQueue,
    embedder: any TextEmbedding,
    model: String,
    mode: SearchMode,
    keywordWeight: Double = 1.0,
    removeStopwords: Bool = false,
    split: EvalSplit = .all
) async throws -> EvalReport {
    let config = EvalConfig(embedder: model, mode: mode, keywordWeight: keywordWeight, stopwords: removeStopwords, split: split)
    // Filtered first, so the corpus check and unscored list also cover only this split.
    let golden = try golden.filter(split.includes)
    let store = ScreenshotStore(db)
    let hashes = try hashGoldenFiles(golden, in: corpus)
    let check = try await checkGoldenFiles(golden, hashes: hashes, store: store)

    // A model the database wasn't indexed with has no vectors, which would score vector search 0
    // and turn fused into keyword-only without a word.
    if mode != .keywordOnly, try await store.allEmbeddings(model: model).isEmpty {
        throw EvalError.noVectors(model: model)
    }
    let engine = SearchEngine(db: db, embedder: embedder, model: model)
    try await engine.reload()

    let clock = ContinuousClock()
    var perQuery: [QueryResult] = []
    var scored: [Scored] = []
    var unscored: [String] = []
    var times: [Double] = []

    for query in golden {
        let relevant = Set(query.relevant.compactMap { hashes[$0] })
        // A relevant file missing from the corpus can never be found, so it still counts against recall.
        let missing = Set(query.relevant.filter { hashes[$0] == nil }).count
        if relevant.isEmpty {
            unscored.append(query.id)
            continue
        }

        let start = clock.now
        let results = try await engine.search(
            query.query, mode: mode, limit: 20, keywordWeight: keywordWeight, removeStopwords: removeStopwords
        )
        times.append(milliseconds(start.duration(to: clock.now)))

        let resultHashes = try await store.fileHashes(for: results.map(\.id))
        let ranked = results.compactMap { resultHashes[$0.id] }
        let hit = hitAtK(ranked, relevant: relevant, k: 5) == 1
        let firstHit = ranked.firstIndex(where: relevant.contains).map { $0 + 1 }

        perQuery.append(QueryResult(
            id: query.id,
            firstHitRank: firstHit,
            top5: results.prefix(5).map { URL(fileURLWithPath: $0.path).lastPathComponent },
            hit: hit
        ))
        scored.append(Scored(
            type: query.type,
            lang: query.lang,
            hitAt5: hit ? 1 : 0,
            recallAt5: query.type == "multi"
                ? recallAtK(ranked, relevant: relevant, k: 5) * Double(relevant.count) / Double(relevant.count + missing)
                : nil,
            reciprocalRank: reciprocalRank(ranked, relevant: relevant)
        ))
    }

    let summary = EvalSummary(
        config: config,
        overall: summarize(scored),
        byType: Dictionary(grouping: scored, by: \.type).mapValues(summarize),
        byLang: Dictionary(grouping: scored, by: \.lang).mapValues(summarize),
        byTypeAndLang: Dictionary(grouping: scored, by: { "\($0.type)/\($0.lang)" }).mapValues(summarize),
        medianQueryMs: percentile(times, 0.5),
        p95QueryMs: percentile(times, 0.95),
        unscoredQueries: unscored.count,
        missingFromCorpus: check.missingFromCorpus.count,
        notIndexedFailed: check.failed.count,
        notIndexedUnfinished: check.unfinished.count
    )
    return EvalReport(check: check, unscored: unscored, perQuery: perQuery, summary: summary)
}

/// Writes per_query.jsonl and summary.json into a new folder. Never overwrites an earlier run.
public func writeEvalResults(_ report: EvalReport, to folder: URL) throws {
    let files = FileManager.default
    guard !files.fileExists(atPath: folder.path) else { throw EvalError.resultsExist(folder.path) }
    try files.createDirectory(at: folder, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var lines = Data()
    for result in report.perQuery {
        lines.append(try encoder.encode(result))
        lines.append(Data("\n".utf8))
    }
    try lines.write(to: folder.appending(path: "per_query.jsonl"))

    encoder.outputFormatting.insert(.prettyPrinted)
    try encoder.encode(report.summary).write(to: folder.appending(path: "summary.json"))
}

/// Hash of every golden filename present in the corpus, matched by exact name as build_golden.py does.
private func hashGoldenFiles(_ golden: [GoldenQuery], in corpus: URL) throws -> [String: String] {
    // Throws for a mistyped corpus, which would otherwise report every golden file missing.
    let names = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
    // Both sides NFC, because macOS may list a filename in NFD.
    let corpusNames = Dictionary(names.map { (Screenshot.normalizedPath($0), $0) }, uniquingKeysWith: { first, _ in first })
    let hasher = FileHasher()
    var hashes: [String: String] = [:]
    for name in Set(golden.flatMap(\.relevant)) {
        guard let onDisk = corpusNames[Screenshot.normalizedPath(name)],
              let hash = try? hasher.sha256(of: corpus.appending(path: onDisk))
        else { continue }
        hashes[name] = hash
    }
    return hashes
}

private func checkGoldenFiles(_ golden: [GoldenQuery], hashes: [String: String], store: ScreenshotStore) async throws -> CorpusCheck {
    let names = Set(golden.flatMap(\.relevant)).sorted()
    let statuses = try await store.statuses(forHashes: Array(Set(hashes.values)))
    var missing: [String] = []
    var failed: [String] = []
    var unfinished: [String] = []
    for name in names {
        guard let hash = hashes[name] else {
            missing.append(name)
            continue
        }
        switch statuses[hash] {
        case .indexed: break
        case .failed: failed.append(name)
        default: unfinished.append(name)
        }
    }
    return CorpusCheck(missingFromCorpus: missing, failed: failed, unfinished: unfinished)
}

private func summarize(_ queries: [Scored]) -> MetricSummary {
    let recalls = queries.compactMap(\.recallAt5)
    return MetricSummary(
        queries: queries.count,
        hitAt5: mean(queries.map(\.hitAt5)),
        multiQueries: recalls.count,
        recallAt5: recalls.isEmpty ? nil : mean(recalls),
        mrr: mean(queries.map(\.reciprocalRank))
    )
}

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

/// Nearest-rank percentile: the smallest value with at least `fraction` of the values at or below it.
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[max(rank, 1) - 1]
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
