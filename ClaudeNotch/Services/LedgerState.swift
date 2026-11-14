import Foundation

/// The pure half of the ledger: which message counted on which day. Kept apart from the
/// file walking so the bucketing — midnight, the 7-day edge, a reply split over several
/// lines — is testable without a disk.
struct LedgerState {
    /// Rolling window the "week" figure covers, and how long entries are kept.
    static let window: TimeInterval = 7 * 24 * 3600

    private struct Entry { var time: Date; var counts: TokenCounts }
    private var byID: [String: Entry] = [:]
    private var anonymous: [Entry] = []

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    mutating func ingest(line: Data) {
        // Cheap byte checks first: almost every line in a transcript is something else.
        guard line.range(of: Self.usageMarker) != nil,
              line.range(of: Self.assistantMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let time = iso.date(from: stamp) ?? isoPlain.date(from: stamp)
        else { return }
        record(id: message["id"] as? String, time: time, counts: TokenCounts(usage: usage))
    }

    /// A later line for the same message replaces the earlier one (see `TokenTally`).
    mutating func record(id: String?, time: Date, counts: TokenCounts) {
        let entry = Entry(time: time, counts: counts)
        if let id { byID[id] = entry } else { anonymous.append(entry) }
    }

    /// Today = since local midnight. Week = the last seven days, rolling.
    func totals(now: Date, calendar: Calendar = .current) -> (today: TokenCounts, week: TokenCounts) {
        let midnight = calendar.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-Self.window)
        var today = TokenCounts(), week = TokenCounts()
        for entry in Array(byID.values) + anonymous where entry.time <= now {
            if entry.time >= weekStart { week += entry.counts }
            if entry.time >= midnight { today += entry.counts }
        }
        return (today, week)
    }

    mutating func prune(now: Date) {
        let edge = now.addingTimeInterval(-Self.window)
        byID = byID.filter { $0.value.time >= edge }
        anonymous.removeAll { $0.time < edge }
    }
}
