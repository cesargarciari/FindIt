import Testing
@testable import FindItCore

struct IndexConfigTests {
    // Ollama names include a tag, so "nomic-embed-text:latest" must get the prefixes too.
    @Test(arguments: ["nomic-embed-text", "nomic-embed-text:latest"])
    func nomicGetsPrefixes(model: String) {
        #expect(documentPrefix(for: model) == "search_document: ")
        #expect(queryPrefix(for: model) == "search_query: ")
    }

    @Test(arguments: ["bge-m3", "bge-m3:latest"])
    func otherModelsGetNoPrefix(model: String) {
        #expect(documentPrefix(for: model) == "")
        #expect(queryPrefix(for: model) == "")
    }
}
