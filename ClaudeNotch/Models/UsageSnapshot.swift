import Foundation

/// Aggregate usage shown in the dashboard and the closed-notch mini readout.
struct UsageSnapshot: Equatable {
    /// 5-hour rolling window.
    var fiveHourPercent: Double        // 0...1 used
    var fiveHourResetsIn: String       // "4h10m"
    /// 7-day rolling window.
    var weeklyPercent: Double          // 0...1 used
    var weeklyResetsIn: String         // "6d12h"

    // Local token accounting (from transcripts).
    var sessionTokens: Int
    var todayTokens: Int
    var weekTokens: Int

    var isLive: Bool                   // true if fetched from the usage endpoint

    static let empty = UsageSnapshot(
        fiveHourPercent: 0, fiveHourResetsIn: "—",
        weeklyPercent: 0, weeklyResetsIn: "—",
        sessionTokens: 0, todayTokens: 0, weekTokens: 0, isLive: false
    )
}
