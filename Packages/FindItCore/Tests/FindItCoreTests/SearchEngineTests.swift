import GRDB
import Testing
@testable import FindItCore

struct SearchEngineTests {
    private let queue: DatabaseQueue
    private let store: ScreenshotStore
    // The fake embeds every query as [0.6, 0.8].
    private let embedder = FakeTextEmbedder(vector: [0.6, 0.8])

    init() throws {
        queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        store = ScreenshotStore(queue)
    }

    private func index(_ name: String, text: String, vector: [Float], model: String = "bge-m3") async throws -> Int64 {
        let id = try #require(try await store.insertPending(path: "/\(name).png", fileHash: name))
        try await store.saveIndexed(id: id, labels: [], searchableText: text, vector: vector, model: model)
        return id
    }

    /// Keyword search finds only `receipt`; vector search ranks ticket, mug, receipt.
    private func seed() async throws -> (receipt: Int64, ticket: Int64, mug: Int64) {
        let receipt = try await index("receipt", text: "coffee receipt", vector: [1, 0])
        let ticket = try await index("ticket", text: "flight ticket", vector: [0.6, 0.8])
        let mug = try await index("mug", text: "mug photo", vector: [0, 1])
        return (receipt, ticket, mug)
    }

    private func makeEngine(model: String = "bge-m3") -> SearchEngine {
        SearchEngine(db: queue, embedder: embedder, model: model)
    }

    @Test func fusedMergesBothSearchesAndMarksOverlapAsBoth() async throws {
        let ids = try await seed()
        let engine = makeEngine()
        try await engine.reload()

        let results = try await engine.search("coffee")

        // receipt is in both lists, so fusion ranks it above ticket, the top vector hit.
        #expect(results == [
            SearchResult(id: ids.receipt, path: "/receipt.png", foundBy: .both),
            SearchResult(id: ids.ticket, path: "/ticket.png", foundBy: .meaning),
            SearchResult(id: ids.mug, path: "/mug.png", foundBy: .meaning),
        ])
    }

    @Test func keywordOnlySkipsTheEmbedder() async throws {
        let ids = try await seed()
        let engine = makeEngine()
        try await engine.reload()

        let results = try await engine.search("coffee", mode: .keywordOnly)

        #expect(results == [SearchResult(id: ids.receipt, path: "/receipt.png", foundBy: .keyword)])
        #expect(embedder.callCount == 0)
    }

    @Test func vectorOnlyRanksByMeaning() async throws {
        let ids = try await seed()
        let engine = makeEngine()
        try await engine.reload()

        let results = try await engine.search("coffee", mode: .vectorOnly)

        #expect(results.map(\.id) == [ids.ticket, ids.mug, ids.receipt])
        #expect(results.allSatisfy { $0.foundBy == .meaning })
    }

    @Test func keepsOnlyTheTopLimit() async throws {
        let ids = try await seed()
        let engine = makeEngine()
        try await engine.reload()

        let results = try await engine.search("coffee", limit: 2)

        #expect(results.map(\.id) == [ids.receipt, ids.ticket])
    }

    @Test func emptyQueryReturnsNothingWithoutEmbedding() async throws {
        _ = try await seed()
        let engine = makeEngine()
        try await engine.reload()

        #expect(try await engine.search("").isEmpty)
        #expect(try await engine.search("   ").isEmpty)
        #expect(embedder.callCount == 0)
    }

    @Test func searchBeforeReloadReturnsKeywordResults() async throws {
        let ids = try await seed()
        let engine = makeEngine()

        let results = try await engine.search("coffee")

        #expect(results == [SearchResult(id: ids.receipt, path: "/receipt.png", foundBy: .keyword)])
    }

    @Test func queryGetsTheModelsPrefix() async throws {
        _ = try await index("receipt", text: "coffee receipt", vector: [1, 0], model: "nomic-embed-text")
        let engine = makeEngine(model: "nomic-embed-text")
        try await engine.reload()

        _ = try await engine.search("coffee", mode: .vectorOnly)

        #expect(embedder.receivedTexts == [["search_query: coffee"]])
    }

    @Test func embedderFailureIsThrown() async throws {
        _ = try await seed()
        let engine = SearchEngine(db: queue, embedder: FakeTextEmbedder(failure: .always), model: "bge-m3")
        try await engine.reload()

        await #expect(throws: FakeError.self) {
            try await engine.search("coffee")
        }
    }

    @Test func emptyEmbeddingThrows() async throws {
        _ = try await seed()
        let engine = SearchEngine(db: queue, embedder: FakeTextEmbedder(vector: []), model: "bge-m3")
        try await engine.reload()

        await #expect(throws: SearchError.emptyEmbedding) {
            try await engine.search("coffee")
        }
    }
}
