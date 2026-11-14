import Foundation

/// Decides when a usage window deserves a heads-up: once at 80 %, once at 95 %, and once
/// when a window you had pushed past 80 % resets. Pure — the caller persists `fired`
/// and turns alerts into notifications — so the "exactly once" rules are testable.
///
/// A threshold is remembered per window *and* per reset time, so the same 80 % doesn't
/// ring again after a relaunch, but does ring again in the next window.
enum UsageAlerts {
    enum Window: String, CaseIterable {
        case fiveHour, weekly, opus
    }

    enum Kind: Equatable {
        case threshold(Int)     // percent crossed: 80 or 95
        case reset
    }

    struct Alert: Equatable {
        var window: Window
        var kind: Kind
        var resetsAt: Date?
    }

    static let thresholds = [80, 95]
    /// A reset is only news if the window had been getting tight.
    static let resetWorthyPercent = 80

    static func evaluate(previous: UsageSnapshot?, current: UsageSnapshot,
                         fired: Set<String>) -> (alerts: [Alert], fired: Set<String>) {
        guard current.isLive else { return ([], fired) }
        var fired = fired
        var alerts: [Alert] = []

        for window in Window.allCases {
            guard let now = reading(window, current) else { continue }
            let pct = Int((now.percent * 100).rounded(.down))

            // Only the highest newly crossed threshold speaks; lower ones are marked
            // so a jump from 70 % to 96 % gives one alert, not two.
            let crossed = thresholds.filter { pct >= $0 && !fired.contains(key(window, now.resetsAt, $0)) }
            if let top = crossed.max() {
                alerts.append(Alert(window: window, kind: .threshold(top), resetsAt: now.resetsAt))
                for t in thresholds where t <= top { fired.insert(key(window, now.resetsAt, t)) }
            }

            if let previous, let before = reading(window, previous), before.percent * 100 >= Double(resetWorthyPercent),
               now.percent < before.percent - 0.3, now.resetsAt != before.resetsAt {
                alerts.append(Alert(window: window, kind: .reset, resetsAt: now.resetsAt))
            }
        }

        // Keys for windows that reset long ago can go; keep the set small.
        if fired.count > 60 { fired = Set(fired.sorted().suffix(30)) }
        return (alerts, fired)
    }

    private static func reading(_ window: Window, _ s: UsageSnapshot) -> (percent: Double, resetsAt: Date?)? {
        switch window {
        case .fiveHour: return (s.fiveHourPercent, s.fiveHourResetsAt)
        case .weekly:   return (s.weeklyPercent, s.weeklyResetsAt)
        case .opus:     return s.opusPercent.map { ($0, s.opusResetsAt) }
        }
    }

    /// Reset times drift by seconds between fetches; rounding to the hour keeps one
    /// window's key stable without merging two different windows.
    static func key(_ window: Window, _ resetsAt: Date?, _ threshold: Int) -> String {
        let hour = resetsAt.map { Int(($0.timeIntervalSince1970 / 3600).rounded()) } ?? 0
        return "\(window.rawValue)|\(hour)|\(threshold)"
    }
}
