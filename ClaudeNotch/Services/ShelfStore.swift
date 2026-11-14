import AppKit
import Observation

/// The file shelf: a small list of files parked on the notch, dragged in from anywhere and
/// dragged back out again.
///
/// Entirely event-driven — nothing polls, nothing watches the filesystem. A file that has
/// gone missing is discovered when the shelf is next opened, which is the only moment the
/// answer matters.
@MainActor
@Observable
final class ShelfStore {

    private(set) var items: [ShelfItem] = []

    /// Whether the shelf tab is offered at all (Settings → Shelf).
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "shelfEnabled")
        }
    }

    /// Guard rail rather than a real limit: the shelf is a staging area, and a list long
    /// enough to scroll for is a folder, not a shelf. The oldest item drops off the end.
    static let capacity = 30

    private let fileURL = UnixSocket.appSupportDir().appendingPathComponent("shelf.json")

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "shelfEnabled") == nil { defaults.set(true, forKey: "shelfEnabled") }
        enabled = defaults.bool(forKey: "shelfEnabled")
        load()
    }

    // MARK: Mutations

    /// Adds files, newest first. Returns how many were actually taken.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let standardized = url.standardizedFileURL
            // Deduplicated by path rather than by bookmark: two bookmarks to the same file
            // are different blobs, so comparing those would let the same file pile up.
            if items.contains(where: { $0.currentPath == standardized.path }) { continue }
            var item = ShelfItem(url: standardized)
            item.resolve()
            items.insert(item, at: 0)
            added += 1
        }
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        if added > 0 { save() }
        return added
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Re-checks every bookmark. Cheap enough to run when the shelf appears, and that is
    /// the only place it is called from.
    func refresh() {
        guard !items.isEmpty else { return }
        for index in items.indices { items[index].resolve() }
    }

    // MARK: Actions

    func open(_ item: ShelfItem) {
        guard !item.isMissing else { return }
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ item: ShelfItem) {
        guard !item.isMissing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func icon(for item: ShelfItem) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.currentPath)
    }

    /// Size on disk, or nil for a file we can't reach.
    func size(of item: ShelfItem) -> Int64? {
        guard !item.isMissing,
              let values = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }
        for index in decoded.indices { decoded[index].resolve() }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
