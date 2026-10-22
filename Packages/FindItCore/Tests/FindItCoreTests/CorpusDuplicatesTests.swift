import Foundation
import Testing
@testable import FindItCore

struct CorpusDuplicatesTests {
    @Test func reportsEachCopyWithTheFileItDuplicates() throws {
        let duplicates = try withTemporaryDirectory { folder in
            for (name, bytes) in [("a.png", "one"), ("b.png", "two"), ("c.png", "one"), ("d.png", "one"), ("e.png", "two")] {
                try Data(bytes.utf8).write(to: folder.appending(path: name))
            }
            // Out of order on purpose: the first by name is the original, whatever order the list is in.
            let urls = ["d.png", "a.png", "e.png", "b.png", "c.png"].map { folder.appending(path: $0) }
            return findDuplicates(in: urls)
        }

        #expect(duplicates == [
            CorpusDuplicate(file: "c.png", original: "a.png"),
            CorpusDuplicate(file: "d.png", original: "a.png"),
            CorpusDuplicate(file: "e.png", original: "b.png"),
        ])
    }

    @Test func unreadableFilesAndUniqueFilesAreNotDuplicates() throws {
        let duplicates = try withTemporaryDirectory { folder in
            try Data("one".utf8).write(to: folder.appending(path: "a.png"))
            try Data("two".utf8).write(to: folder.appending(path: "b.png"))
            let urls = ["a.png", "b.png", "missing.png"].map { folder.appending(path: $0) }
            return findDuplicates(in: urls)
        }

        #expect(duplicates.isEmpty)
    }
}
