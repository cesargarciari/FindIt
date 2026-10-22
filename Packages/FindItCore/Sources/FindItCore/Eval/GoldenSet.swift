import Foundation

/// One line of eval/golden.jsonl, as written by scripts/build_golden.py.
public struct GoldenQuery: Codable, Equatable, Sendable {
    public let id: String
    public let query: String
    /// Filenames in the corpus, matched by exact name.
    public let relevant: [String]
    public let type: String
    public let lang: String
}

public enum GoldenSetError: Error, Equatable, Sendable {
    /// `line` counts from 1, so it matches what an editor shows.
    case malformedLine(Int, reason: String)
}

/// Reads one query per line, skipping blank lines.
public func loadGolden(at url: URL) throws -> [GoldenQuery] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var queries: [GoldenQuery] = []
    // Swift reads "\r\n" as one Character, so a Windows file splits into the same lines and numbers.
    for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        do {
            queries.append(try JSONDecoder().decode(GoldenQuery.self, from: Data(line.utf8)))
        } catch {
            throw GoldenSetError.malformedLine(index + 1, reason: String(describing: error))
        }
    }
    return queries
}
