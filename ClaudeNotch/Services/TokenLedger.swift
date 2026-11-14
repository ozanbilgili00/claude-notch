import Foundation

/// Today's and this week's token totals across every Claude Code session, including ones
/// the notch never saw start. Built from the transcripts under `~/.claude/projects`.
///
/// Those files are large — a busy week is hundreds of megabytes — so the ledger never
/// re-reads: it keeps a byte offset per file and only parses what was appended since the
/// last pass, and of that only lines that can carry usage (assistant messages) reach the
/// JSON parser at all.
final class TokenLedger: @unchecked Sendable {
    private weak var store: SessionStore?
    private let root: URL
    private let queue = DispatchQueue(label: "com.ozan.ClaudeNotch.ledger", qos: .utility)
    private var timer: Timer?

    // Queue-confined.
    private var state = LedgerState()
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: Data] = [:]

    init(store: SessionStore,
         root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")) {
        self.store = store
        self.root = root
    }

    @MainActor func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @MainActor func stop() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.scan()
            let totals = self.state.totals(now: Date())
            Task { @MainActor [weak store = self.store] in
                store?.usage.todayTokens = totals.today.main
                store?.usage.weekTokens = totals.week.main
            }
        }
    }

    // MARK: Scanning (queue)

    private func scan() {
        let cutoff = Date().addingTimeInterval(-LedgerState.window)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }

        var seen = Set<String>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified > cutoff else { continue }
            seen.insert(url.path)
            ingest(url.path)
        }
        // Forget files that aged out or were deleted, so the maps don't grow forever.
        offsets = offsets.filter { seen.contains($0.key) }
        partial = partial.filter { seen.contains($0.key) }
        state.prune(now: Date())
    }

    private func ingest(_ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var offset = offsets[path] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial[path] = nil }    // truncated or replaced
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)

        var carry = partial[path] ?? Data()
        let chunk = 4 << 20
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            offset += UInt64(data.count)
            carry.append(data)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                state.ingest(line: carry[start..<nl])
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
        }
        offsets[path] = offset
        partial[path] = carry
    }
}
