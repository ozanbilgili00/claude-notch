import Foundation
import Observation

/// One finished turn, as remembered for the daily summary.
struct DailyEntry: Codable, Equatable {
    var time: Date
    var project: String
    var duration: TimeInterval
    var added: Int
    var removed: Int
    var succeeded: Bool
}

/// What "today" adds up to.
struct DailySummary: Equatable {
    var turns = 0
    var failures = 0
    var duration: TimeInterval = 0
    var added = 0
    var removed = 0
    /// Most-worked-on first.
    var projects: [String] = []

    var isEmpty: Bool { turns == 0 }
}

/// Every finished turn of the last two weeks, kept on disk so the "Today" card survives
/// a relaunch. Small by construction: a record per turn, trimmed to 14 days on each write.
@MainActor
@Observable
final class DailyLog {
    static let shared = DailyLog()

    nonisolated static let keepDays = 14

    private(set) var entries: [DailyEntry] = []
    @ObservationIgnored private let url: URL?

    init(url: URL? = DailyLog.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode([DailyEntry].self, from: data) {
            entries = saved
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClaudeNotch/daily.json")
    }

    func record(_ entry: DailyEntry) {
        entries = Self.trimmed(entries + [entry], now: entry.time)
        save()
    }

    func today(now: Date = Date()) -> DailySummary {
        Self.summarize(entries, now: now)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder.iso.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Pure

    nonisolated static func trimmed(_ entries: [DailyEntry], now: Date,
                                    calendar: Calendar = .current) -> [DailyEntry] {
        guard let edge = calendar.date(byAdding: .day, value: -keepDays,
                                       to: calendar.startOfDay(for: now)) else { return entries }
        return entries.filter { $0.time >= edge }
    }

    nonisolated static func summarize(_ entries: [DailyEntry], now: Date,
                                      calendar: Calendar = .current) -> DailySummary {
        let midnight = calendar.startOfDay(for: now)
        var s = DailySummary()
        var perProject: [String: Int] = [:]
        for e in entries where e.time >= midnight && e.time <= now {
            s.turns += 1
            if !e.succeeded { s.failures += 1 }
            s.duration += e.duration
            s.added += e.added
            s.removed += e.removed
            perProject[e.project, default: 0] += 1
        }
        s.projects = perProject.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        return s
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
