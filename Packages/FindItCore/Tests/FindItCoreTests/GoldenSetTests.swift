import Foundation
import Testing
@testable import FindItCore

// Every query here is invented; the real golden set is private and never read by tests.
struct GoldenSetTests {
    private func load(_ contents: String) throws -> [GoldenQuery] {
        try withTemporaryDirectory { folder in
            let url = folder.appending(path: "golden.jsonl")
            try Data(contents.utf8).write(to: url)
            return try loadGolden(at: url)
        }
    }

    @Test func readsQueriesAndSkipsBlankLines() throws {
        let queries = try load("""
            {"id":"q1","query":"red umbrella on a bridge","relevant":["a.png"],"type":"visual","lang":"en"}

            {"id":"q2","query":"factura de la luz","relevant":["b.png","C.PNG"],"type":"multi","lang":"es"}
            \("   ")
            """)

        #expect(queries.map(\.id) == ["q1", "q2"])
        #expect(queries[1].query == "factura de la luz")
        #expect(queries[1].relevant == ["b.png", "C.PNG"])
        #expect(queries[1].type == "multi")
        #expect(queries[1].lang == "es")
    }

    @Test func reportsLineNumberOfMalformedLine() throws {
        let contents = """
            {"id":"q1","query":"a cat","relevant":["a.png"],"type":"visual","lang":"en"}

            {"id":"q2","query":"missing relevant","type":"visual","lang":"en"}
            """

        #expect {
            _ = try load(contents)
        } throws: { error in
            // Line 3, counting the blank line, so it matches the line an editor shows.
            if case GoldenSetError.malformedLine(3, _) = error { true } else { false }
        }
    }

    @Test func windowsLineEndingsKeepLineNumbers() throws {
        let contents = "{\"id\":\"q1\",\"query\":\"x\",\"relevant\":[\"a.png\"],\"type\":\"visual\",\"lang\":\"en\"}\r\nnot json\r\n"

        #expect {
            _ = try load(contents)
        } throws: { error in
            if case GoldenSetError.malformedLine(2, _) = error { true } else { false }
        }
    }
}
