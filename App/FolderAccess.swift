import Foundation

/// Remembers the watched folder across launches. The sandbox forgets picker access when the app
/// quits, so the folder is saved as a security-scoped bookmark.
enum FolderAccess {
    private static let key = "watchedFolderBookmark"

    static func save(_ folder: URL) throws {
        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: key)
    }

    /// The saved folder with access started, or nil when none was saved or it can't be reached.
    /// Access stays on for the life of the app, since indexing and thumbnails read from it.
    static func restore() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), folder.startAccessingSecurityScopedResource() else {
            return nil
        }
        // A moved or renamed folder still resolves, but its bookmark should be refreshed.
        if isStale {
            try? save(folder)
        }
        return folder
    }
}
