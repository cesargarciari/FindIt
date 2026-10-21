import Foundation
import Testing
@testable import FindItCore

struct FileHasherTests {
    private func hash(of contents: String) throws -> String {
        try withTemporaryDirectory { folder in
            let url = folder.appending(path: "file.txt")
            try Data(contents.utf8).write(to: url)
            return try FileHasher().sha256(of: url)
        }
    }

    @Test func hashesAbc() throws {
        #expect(try hash(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hashesEmptyFile() throws {
        #expect(try hash(of: "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

struct FolderScannerTests {
    @Test func returnsOnlyImagesSortedByName() throws {
        let names = try withTemporaryDirectory { folder in
            let files = ["c.HEIC", "a.png", "notes.txt", "b.JPG", "d.jpeg", "e.gif", "Makefile", ".hidden.png"]
            for name in files {
                try Data([0]).write(to: folder.appending(path: name))
            }
            try FileManager.default.createDirectory(at: folder.appending(path: "folder.png"), withIntermediateDirectories: false)

            return try FolderScanner().imageFiles(in: folder).map(\.lastPathComponent)
        }

        #expect(names == ["a.png", "b.JPG", "c.HEIC", "d.jpeg"])
    }

    @Test func missingFolderThrows() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "FindItTests-missing-\(UUID().uuidString)")

        #expect(throws: (any Error).self) {
            try FolderScanner().imageFiles(in: missing)
        }
    }
}
