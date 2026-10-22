import Foundation

/// A corpus file with the same bytes as an earlier one, so indexing keeps only the original.
public struct CorpusDuplicate: Equatable, Sendable {
    public let file: String
    /// The first file by name with the same bytes.
    public let original: String
}

/// Byte-identical files among `urls`, by filename. The first by name counts as the original,
/// matching the order FolderScanner lists them in. Unreadable files are left out; enqueue reports those.
public func findDuplicates(in urls: [URL]) -> [CorpusDuplicate] {
    let hasher = FileHasher()
    var originals: [String: String] = [:]
    var duplicates: [CorpusDuplicate] = []
    for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let hash = try? hasher.sha256(of: url) else { continue }
        let name = url.lastPathComponent
        if let original = originals[hash] {
            duplicates.append(CorpusDuplicate(file: name, original: original))
        } else {
            originals[hash] = name
        }
    }
    return duplicates
}
