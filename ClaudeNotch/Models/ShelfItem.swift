import Foundation

/// One file parked on the shelf.
///
/// A *reference*, never a copy: the shelf holds a bookmark to wherever the file actually
/// lives, so it costs no disk space and editing the original edits what the shelf hands
/// back. The trade-off is that the file can move or vanish behind our back, which is what
/// `resolve()` and `isMissing` exist to report rather than hide.
struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Bookmark data, which survives the file being renamed or moved. Not security-scoped:
    /// the app is not sandboxed (verified via `codesign -d --entitlements`), so a plain
    /// bookmark resolves without needing to be started and stopped around every access.
    var bookmark: Data
    /// Path captured when the file was added. Kept alongside the bookmark as the label to
    /// show — and as the fallback identity — when the bookmark no longer resolves.
    var lastKnownPath: String
    var addedAt: Date

    /// Set once a resolve attempt has failed. Purely presentational: a missing file stays
    /// on the shelf, because "the external drive is unplugged" is not the same as
    /// "I'm done with this file", and only the user gets to decide the second one.
    var isMissing: Bool = false

    var displayName: String {
        (currentPath as NSString).lastPathComponent
    }

    var fileExtension: String {
        (currentPath as NSString).pathExtension.uppercased()
    }

    /// The resolved path if the bookmark still points somewhere, else the original one.
    var currentPath: String { resolvedPath ?? lastKnownPath }

    /// Cached across a resolve so the row doesn't hit the disk on every redraw.
    private var resolvedPath: String?

    var url: URL { URL(fileURLWithPath: currentPath) }

    init(url: URL) {
        self.id = UUID()
        self.bookmark = (try? url.bookmarkData()) ?? Data()
        self.lastKnownPath = url.path
        self.resolvedPath = url.path
        self.addedAt = Date()
    }

    /// Re-points the item at wherever the file is now. Called at launch and after the
    /// file is used, not on every draw.
    mutating func resolve() {
        var stale = false
        guard !bookmark.isEmpty,
              let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withoutUI], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path)
        else {
            // Bookmarks fail for a file that was deleted *and* for one on a volume that
            // isn't mounted; fall back to the recorded path before giving up, since a file
            // restored to its old location resolves that way even with a dead bookmark.
            isMissing = !FileManager.default.fileExists(atPath: lastKnownPath)
            resolvedPath = isMissing ? nil : lastKnownPath
            return
        }
        isMissing = false
        resolvedPath = url.path
        lastKnownPath = url.path
        if stale, let fresh = try? url.bookmarkData() { bookmark = fresh }
    }

    // Only the durable half is persisted; `resolvedPath` is rebuilt at launch.
    private enum CodingKeys: String, CodingKey {
        case id, bookmark, lastKnownPath, addedAt
    }
}
