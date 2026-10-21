import Foundation

/// Lists the image files directly inside a folder. Does not look in subfolders.
public struct FolderScanner: Sendable {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    public init() {}

    /// Returns png, jpg, jpeg and heic files (any letter case), sorted by filename.
    public func imageFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            // isRegularFile is false for folders (a folder named "x.png" is not an image) and for
            // symlinks, which are deliberately skipped so a link can't pull in files from outside
            // the folder. Subfolders are never entered either; contentsOfDirectory lists one level.
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            // Plain string order, so results don't depend on the user's locale.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
