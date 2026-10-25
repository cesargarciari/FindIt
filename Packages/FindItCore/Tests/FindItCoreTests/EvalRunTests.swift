import Foundation
import GRDB
import Testing
@testable import FindItCore

// Every query and file here is invented; the real golden set and corpus are private.
/// What runEval needs to build its search engine.
private struct EngineParts {
    let embedder: FakeTextEmbedder
    let model: String
}

struct EvalRunTests {
    private let db: DatabaseQueue
    private let store: ScreenshotStore

    init() throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = ScreenshotStore(db)
    }

    private let golden = [
        GoldenQuery(id: "q1", query: "umbrella", relevant: ["a.png"], type: "visual", lang: "en"),
        GoldenQuery(id: "q2", query: "factura", relevant: ["b.png"], type: "paraphrase", lang: "es"),
        // copy-of-a.png has a's bytes, so it was never stored itself; it must still count through a.
        GoldenQuery(id: "q3", query: "cat umbrella", relevant: ["c.png", "copy-of-a.png"], type: "multi", lang: "en"),
        GoldenQuery(id: "q4", query: "nothing here", relevant: ["d.png", "gone.png"], type: "exact_text", lang: "en"),
        GoldenQuery(id: "q5", query: "umbrella", relevant: ["e.png"], type: "visual", lang: "es"),
        // None of its files is in the corpus, so it can't be scored.
        GoldenQuery(id: "q6", query: "anything", relevant: ["gone.png"], type: "visual", lang: "en"),
    ]

    /// Writes the corpus and indexes a, b and c; d failed and e was never enqueued.
    private func makeCorpus(in folder: URL) async throws {
        for (name, width) in [("a.png", 64), ("b.png", 65), ("c.png", 66), ("d.png", 67), ("e.png", 68)] {
            try TestImages.write(TestImages.make(width: width, height: 48), to: folder.appending(path: name))
        }
        try FileManager.default.copyItem(at: folder.appending(path: "a.png"), to: folder.appending(path: "copy-of-a.png"))

        let indexed: [(String, String, [Float])] = [
            ("a.png", "red umbrella on a bridge", [1, 0]),
            ("b.png", "factura de la luz enero", [0, 1]),
            ("c.png", "cat asleep on a sofa", [0.6, 0.8]),
        ]
        for (name, text, vector) in indexed {
            let url = folder.appending(path: name)
            let id = try #require(try await store.insertPending(path: url.path, fileHash: try FileHasher().sha256(of: url)))
            try await store.saveIndexed(id: id, labels: [], searchableText: text, vector: vector, model: "bge-m3")
        }
        let failedURL = folder.appending(path: "d.png")
        let failed = try #require(try await store.insertPending(path: failedURL.path, fileHash: try FileHasher().sha256(of: failedURL)))
        try await store.markFailed(id: failed, reason: "emptyEmbedding")
    }

    private func evaluate(mode: SearchMode) async throws -> EvalReport {
        try await withTemporaryDirectory { folder in
            try await makeCorpus(in: folder)
            // The fake embeds every query as [1, 0], so vector search ranks a, then c, then b.
            let engine = EngineParts(embedder: FakeTextEmbedder(vector: [1, 0]), model: "bge-m3")
            return try await runEval(golden: golden, corpus: folder, db: db, embedder: engine.embedder, model: engine.model, mode: mode)
        }
    }

    @Test func reportsGoldenFilesThatSearchCannotFind() async throws {
        let report = try await evaluate(mode: .keywordOnly)

        #expect(report.check == CorpusCheck(missingFromCorpus: ["gone.png"], failed: ["d.png"], unfinished: ["e.png"]))
        #expect(report.unscored == ["q6"])
        #expect(report.summary.missingFromCorpus == 1)
        #expect(report.summary.notIndexedFailed == 1)
        #expect(report.summary.notIndexedUnfinished == 1)
        #expect(report.summary.unscoredQueries == 1)
    }

    @Test func scoresEachQueryByContent() async throws {
        let report = try await evaluate(mode: .keywordOnly)
        let byId = Dictionary(uniqueKeysWithValues: report.perQuery.map { ($0.id, $0) })

        #expect(report.perQuery.map(\.id) == ["q1", "q2", "q3", "q4", "q5"])
        #expect(byId["q1"] == QueryResult(id: "q1", firstHitRank: 1, top5: ["a.png"], hit: true))
        #expect(byId["q2"] == QueryResult(id: "q2", firstHitRank: 1, top5: ["b.png"], hit: true))
        // Results show the stored filename: a.png, which is what copy-of-a.png matched.
        #expect(byId["q3"]?.firstHitRank == 1)
        #expect(Set(byId["q3"]?.top5 ?? []) == ["a.png", "c.png"])
        #expect(byId["q4"] == QueryResult(id: "q4", firstHitRank: nil, top5: [], hit: false))
        #expect(byId["q5"] == QueryResult(id: "q5", firstHitRank: nil, top5: ["a.png"], hit: false))
    }

    @Test func summarizesOverallAndByGroup() async throws {
        let summary = try await evaluate(mode: .keywordOnly).summary

        #expect(summary.overall == MetricSummary(queries: 5, hitAt5: 0.6, multiQueries: 1, recallAt5: 1, mrr: 0.6))
        #expect(summary.byType["visual"] == MetricSummary(queries: 2, hitAt5: 0.5, multiQueries: 0, recallAt5: nil, mrr: 0.5))
        #expect(summary.byType["multi"] == MetricSummary(queries: 1, hitAt5: 1, multiQueries: 1, recallAt5: 1, mrr: 1))
        #expect(summary.byType["exact_text"]?.hitAt5 == 0)
        #expect(summary.byLang["es"] == MetricSummary(queries: 2, hitAt5: 0.5, multiQueries: 0, recallAt5: nil, mrr: 0.5))
        #expect(abs((summary.byLang["en"]?.hitAt5 ?? -1) - 2.0 / 3.0) < 1e-9)
        #expect(summary.byTypeAndLang["visual/en"]?.hitAt5 == 1)
        #expect(summary.byTypeAndLang["visual/es"]?.hitAt5 == 0)
        #expect(summary.byTypeAndLang.count == 5)
        #expect(summary.medianQueryMs >= 0)
        #expect(summary.p95QueryMs >= summary.medianQueryMs)
    }

    @Test func vectorModeSearchesVectorsLoadedByReload() async throws {
        // No keyword in "anything" matches, so a hit here can only come from vectors read by reload().
        let report = try await withTemporaryDirectory { folder in
            try await makeCorpus(in: folder)
            let engine = EngineParts(embedder: FakeTextEmbedder(vector: [1, 0]), model: "bge-m3")
            let queries = [GoldenQuery(id: "v1", query: "anything", relevant: ["copy-of-a.png"], type: "visual", lang: "en")]
            return try await runEval(golden: queries, corpus: folder, db: db, embedder: engine.embedder, model: engine.model, mode: .vectorOnly)
        }

        #expect(report.perQuery == [QueryResult(id: "v1", firstHitRank: 1, top5: ["a.png", "c.png", "b.png"], hit: true)])
    }

    @Test func recallCountsRelevantFilesMissingFromCorpus() async throws {
        // a and c are found, but gone.png can never be, so recall is 2 of 3, not 2 of 2.
        let report = try await withTemporaryDirectory { folder in
            try await makeCorpus(in: folder)
            let engine = EngineParts(embedder: FakeTextEmbedder(vector: [1, 0]), model: "bge-m3")
            let queries = [GoldenQuery(id: "m1", query: "cat umbrella", relevant: ["a.png", "c.png", "gone.png"], type: "multi", lang: "en")]
            return try await runEval(golden: queries, corpus: folder, db: db, embedder: engine.embedder, model: engine.model, mode: .keywordOnly)
        }

        let recall = try #require(report.summary.overall.recallAt5)
        #expect(abs(recall - 2.0 / 3.0) < 1e-9)
    }

    @Test func unreadableCorpusThrows() async throws {
        let engine = EngineParts(embedder: FakeTextEmbedder(), model: "bge-m3")
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

        await #expect(throws: (any Error).self) {
            _ = try await runEval(golden: golden, corpus: missing, db: db, embedder: engine.embedder, model: engine.model, mode: .keywordOnly)
        }
    }

    @Test(arguments: [SearchMode.fused, .vectorOnly])
    func vectorSearchWithoutVectorsForTheModelThrows(mode: SearchMode) async throws {
        // The database was indexed with bge-m3, so a nomic run would quietly score keyword-only or 0.
        try await withTemporaryDirectory { folder in
            try await makeCorpus(in: folder)
            let engine = EngineParts(embedder: FakeTextEmbedder(), model: "nomic-embed-text")
            await #expect(throws: EvalError.noVectors(model: "nomic-embed-text")) {
                _ = try await runEval(golden: golden, corpus: folder, db: db, embedder: engine.embedder, model: engine.model, mode: mode)
            }
        }
    }

    @Test func keywordModeNeedsNoVectors() async throws {
        try await withTemporaryDirectory { folder in
            try await makeCorpus(in: folder)
            let engine = EngineParts(embedder: FakeTextEmbedder(), model: "nomic-embed-text")
            _ = try await runEval(golden: golden, corpus: folder, db: db, embedder: engine.embedder, model: engine.model, mode: .keywordOnly)
        }
    }

    @Test func percentileUsesNearestRank() {
        let values = (1 ... 20).map(Double.init).shuffled()

        #expect(percentile(values, 0.5) == 10)
        #expect(percentile(values, 0.95) == 19)
        #expect(percentile([7], 0.95) == 7)
        #expect(percentile([], 0.5) == 0)
    }

    @Test func writesResultsWithoutQueryTextAndNeverOverwrites() async throws {
        let report = try await evaluate(mode: .fused)

        try await withTemporaryDirectory { folder in
            let results = folder.appending(path: "results/run-1")
            try writeEvalResults(report, to: results)

            let perQuery = try String(contentsOf: results.appending(path: "per_query.jsonl"), encoding: .utf8)
            let summary = try String(contentsOf: results.appending(path: "summary.json"), encoding: .utf8)
            let lines = perQuery.split(separator: "\n")
            #expect(lines.count == report.perQuery.count)
            #expect(try lines.map { try JSONDecoder().decode(QueryResult.self, from: Data($0.utf8)) } == report.perQuery)
            #expect(try JSONDecoder().decode(EvalSummary.self, from: Data(summary.utf8)) == report.summary)
            for query in golden {
                #expect(!perQuery.contains(query.query))
                #expect(!summary.contains(query.query))
            }

            #expect(throws: EvalError.resultsExist(results.path)) {
                try writeEvalResults(report, to: results)
            }
        }
    }

    /// Builds the corpus once, so `body` can run several evals against it.
    private func withCorpus<T: Sendable>(_ body: (URL) async throws -> T) async throws -> T {
        try await withTemporaryDirectory { folder in
            try await makeCorpus(in: folder)
            return try await body(folder)
        }
    }

    /// Runs `queries` (the shared golden set by default) with the fake embedding every query as [1, 0].
    private func run(
        _ queries: [GoldenQuery]? = nil,
        in corpus: URL,
        mode: SearchMode = .fused,
        keywordWeight: Double = 1.0,
        removeStopwords: Bool = false,
        split: EvalSplit = .all
    ) async throws -> EvalReport {
        try await runEval(
            golden: queries ?? golden, corpus: corpus, db: db, embedder: FakeTextEmbedder(vector: [1, 0]), model: "bge-m3",
            mode: mode, keywordWeight: keywordWeight, removeStopwords: removeStopwords, split: split
        )
    }

    @Test func devSplitScoresOnlyOddIds() async throws {
        let report = try await withCorpus { try await run(in: $0, mode: .keywordOnly, split: .dev) }

        #expect(report.perQuery.map(\.id) == ["q1", "q3", "q5"])
        #expect(report.unscored.isEmpty)
        // The check covers only dev's files, so d.png (q4) and gone.png (q4, q6) aren't reported.
        #expect(report.check == CorpusCheck(missingFromCorpus: [], failed: [], unfinished: ["e.png"]))
    }

    @Test func testSplitScoresOnlyEvenIds() async throws {
        let report = try await withCorpus { try await run(in: $0, mode: .keywordOnly, split: .test) }

        #expect(report.perQuery.map(\.id) == ["q2", "q4"])
        #expect(report.unscored == ["q6"])
    }

    @Test func splitByLastDigitSoQ10IsTest() async throws {
        let queries = [GoldenQuery(id: "q10", query: "umbrella", relevant: ["a.png"], type: "visual", lang: "en")]

        let (test, dev) = try await withCorpus { corpus in
            (try await run(queries, in: corpus, mode: .keywordOnly, split: .test),
             try await run(queries, in: corpus, mode: .keywordOnly, split: .dev))
        }

        #expect(test.perQuery.map(\.id) == ["q10"])
        #expect(dev.perQuery.isEmpty)
    }

    @Test func idWithoutDigitThrowsOnlyWhenSplitting() async throws {
        let queries = [GoldenQuery(id: "umbrella-a", query: "umbrella", relevant: ["a.png"], type: "visual", lang: "en")]

        try await withCorpus { corpus in
            let all = try await run(queries, in: corpus, mode: .keywordOnly)
            #expect(all.perQuery.count == 1)
            await #expect(throws: EvalError.unnumberedQuery("umbrella-a")) {
                _ = try await run(queries, in: corpus, mode: .keywordOnly, split: .dev)
            }
        }
    }

    @Test func keywordWeightReachesSearch() async throws {
        // Keyword search finds only b; vectors rank a, c, b. Weight 0 leaves the vector order.
        let queries = [GoldenQuery(id: "w1", query: "factura", relevant: ["b.png"], type: "exact_text", lang: "es")]

        let (equal, zero) = try await withCorpus { corpus in
            (try await run(queries, in: corpus), try await run(queries, in: corpus, keywordWeight: 0))
        }

        #expect(equal.perQuery.first?.firstHitRank == 1)
        #expect(zero.perQuery.first?.firstHitRank == 3)
    }

    @Test func stopwordsReachSearch() async throws {
        // "on a" matches a and c only through stopwords, so removing them leaves nothing to find.
        let queries = [GoldenQuery(id: "s1", query: "on a", relevant: ["c.png"], type: "exact_text", lang: "en")]

        let (kept, removed) = try await withCorpus { corpus in
            (try await run(queries, in: corpus, mode: .keywordOnly),
             try await run(queries, in: corpus, mode: .keywordOnly, removeStopwords: true))
        }

        #expect(kept.perQuery.first?.hit == true)
        #expect(removed.perQuery.first?.hit == false)
    }

    @Test func summarySavesTheConfig() async throws {
        let report = try await withCorpus { try await run(in: $0, mode: .fused, keywordWeight: 1.5, removeStopwords: true, split: .dev) }

        #expect(report.summary.config == EvalConfig(
            embedder: "bge-m3", mode: .fused, keywordWeight: 1.5, stopwords: true, split: .dev
        ))
        let json = String(decoding: try JSONEncoder().encode(report.summary), as: UTF8.self)
        #expect(json.contains(#""keyword_weight":1.5"#))
        #expect(json.contains(#""mode":"fused""#))
        #expect(json.contains(#""split":"dev""#))
    }
}
