import GRDB
import Testing
@testable import FindItCore

struct KeywordSearchTests {
    private let queue: DatabaseQueue
    private let store: ScreenshotStore

    init() throws {
        queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        store = ScreenshotStore(queue)
    }

    private func index(_ text: String) async throws -> Int64 {
        let id = try #require(try await store.insertPending(path: "/\(text).png", fileHash: text))
        try await store.saveIndexed(id: id, labels: [], searchableText: text, vector: [1, 0], model: "bge-m3")
        return id
    }

    @Test func plainWordFindsAccentedText() async throws {
        let cafe = try await index("Café con leche")
        _ = try await index("flight ticket")

        #expect(try await keywordSearch("cafe", db: queue, limit: 50) == [cafe])
    }

    @Test func matchesAnyWordOfTheQuery() async throws {
        let receipt = try await index("coffee receipt")
        let ticket = try await index("flight ticket")
        _ = try await index("cat photo")

        let ids = try await keywordSearch("receipt ticket", db: queue, limit: 50)

        #expect(Set(ids) == [receipt, ticket])
    }

    @Test func betterMatchComesFirst() async throws {
        let once = try await index("invoice from the hardware store downtown")
        let twice = try await index("invoice invoice")

        #expect(try await keywordSearch("invoice", db: queue, limit: 50) == [twice, once])
    }

    @Test func respectsLimit() async throws {
        for n in 0 ..< 3 {
            _ = try await index("note \(n)")
        }

        #expect(try await keywordSearch("note", db: queue, limit: 2).count == 2)
    }

    @Test func fts5SyntaxInQueryDoesNotThrow() async throws {
        let id = try await index("don't panic")

        let ids = try await keywordSearch(#""don't AND ("#, db: queue, limit: 50)

        #expect(ids == [id])
    }

    @Test func emptyQueryReturnsNothing() async throws {
        _ = try await index("anything")

        #expect(try await keywordSearch("", db: queue, limit: 50).isEmpty)
        #expect(try await keywordSearch("  ( ", db: queue, limit: 50).isEmpty)
    }

    @Test func stopwordsAreKeptByDefault() async throws {
        let receipt = try await index("receipt for coffee")
        let other = try await index("the flight")

        let ids = try await keywordSearch("the receipt", db: queue, limit: 50)

        #expect(Set(ids) == [receipt, other])
    }

    @Test func removingStopwordsSearchesOnlyTheRest() async throws {
        let receipt = try await index("receipt for coffee")
        _ = try await index("the flight")
        _ = try await index("factura de la luz")

        let ids = try await keywordSearch("The receipt de la", db: queue, limit: 50, removeStopwords: true)

        #expect(ids == [receipt])
    }

    @Test func onlyStopwordsReturnsNothing() async throws {
        _ = try await index("the flight")

        #expect(try await keywordSearch("the de la", db: queue, limit: 50, removeStopwords: true).isEmpty)
    }

    @Test func stopwordsMatchWhateverTheCaseAndAccents() {
        #expect(withoutStopwords("Qué ESTÁ en el café") == "café")
    }
}
