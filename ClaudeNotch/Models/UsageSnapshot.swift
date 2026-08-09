import Foundation

/// Aggregate usage shown in the dashboard and the closed-notch mini readout.
struct UsageSnapshot: Equatable {
    // Reset times are kept as dates, not as pre-rendered "4h10m" text. Two reasons:
    // the text was baked when usage was fetched, so it neither counted down between
    // refreshes nor followed a language change until the next fetch.
    /// 5-hour rolling window.
    var fiveHourPercent: Double        // 0...1 used
    var fiveHourResetsAt: Date?
    /// 7-day rolling window.
    var weeklyPercent: Double          // 0...1 used
    var weeklyResetsAt: Date?

    /// Opus-only weekly window. Nil on plans that don't have one.
    var opusPercent: Double?
    var opusResetsAt: Date?

    /// Extra usage credits, when the account has them switched on.
    var extraCreditsUsed: Double?
    var extraCreditsLimit: Double?

    /// The API's own read on how close to the limit we are ("normal"/"warning"/…),
    /// which is better than guessing from a percentage threshold.
    var severity: String?

    // Local token accounting (from transcripts).
    var sessionTokens: Int
    var todayTokens: Int
    var weekTokens: Int

    var isLive: Bool                   // true if fetched from the usage endpoint

    /// True when the API flags the current usage as anything past "normal".
    var isWarning: Bool { severity != nil && severity != "normal" }

    static let empty = UsageSnapshot(
        fiveHourPercent: 0, fiveHourResetsAt: nil,
        weeklyPercent: 0, weeklyResetsAt: nil,
        sessionTokens: 0, todayTokens: 0, weekTokens: 0, isLive: false
    )
}

extension UsageSnapshot {
    /// "4sa10dk" / "4h10m", or "6g12sa" / "6d12h" for spans over a day. Computed where
    /// it is drawn, so it is current in both senses: the remaining time and the language.
    @MainActor
    static func countdown(until date: Date?) -> String {
        guard let date else { return "—" }
        let totalMinutes = Int(max(0, date.timeIntervalSinceNow) / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)\(L(.unitDay))\(hours)\(L(.unitHour))" }
        return "\(hours)\(L(.unitHour))\(minutes)\(L(.unitMinute))"
    }

    @MainActor var fiveHourResetsIn: String { Self.countdown(until: fiveHourResetsAt) }
    @MainActor var weeklyResetsIn: String { Self.countdown(until: weeklyResetsAt) }
    @MainActor var opusResetsIn: String { Self.countdown(until: opusResetsAt) }
}
