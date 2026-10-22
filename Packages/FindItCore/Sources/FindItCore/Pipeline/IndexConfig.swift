public struct IndexConfig: Sendable {
    public var describerModel = "qwen3-vl:8b"
    public var embedderModel = "bge-m3"
    public var maxDimension: Int? = 1024
    public var shortOCRLength = 20        // below this, add image labels
    public init() {}
}

// nomic-embed-text needs a task prefix on every text it embeds. Indexing and search both get
// theirs from here, so they can never disagree. hasPrefix also matches tags like ":latest".

func documentPrefix(for model: String) -> String {
    model.hasPrefix("nomic-embed-text") ? "search_document: " : ""
}

func queryPrefix(for model: String) -> String {
    model.hasPrefix("nomic-embed-text") ? "search_query: " : ""
}
