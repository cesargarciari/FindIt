import CryptoKit
import Foundation

/// Hashes file contents so the same image is never indexed twice.
public struct FileHasher: Sendable {
    // Reading in chunks keeps memory flat for large images.
    private static let chunkSize = 1 << 20

    public init() {}

    /// Returns the lowercase hex SHA-256 of the file's bytes.
    public func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
