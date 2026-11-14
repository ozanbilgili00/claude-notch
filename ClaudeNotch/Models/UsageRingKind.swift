import SwiftUI

/// One ring in the edge dock.
///
/// The reference design Ozan sent stacks three rings for three different AI providers. We
/// only have honest numbers for one of them, so the rings here are the four readouts this
/// app actually measures — three usage windows and the live session state. Which of them
/// appear is the user's choice (Settings → Yerleşim); the order is fixed by the enum so
/// the dock doesn't reshuffle itself between launches.
enum UsageRingKind: String, CaseIterable, Codable, Identifiable {
    case fiveHour
    case weekly
    case opus
    case sessions

    var id: String { rawValue }

    /// What the dock shows by default: the two windows every plan has.
    static let defaults: [UsageRingKind] = [.fiveHour, .weekly]

    var symbol: String {
        switch self {
        case .fiveHour: return "clock.fill"
        case .weekly:   return "calendar"
        case .opus:     return "sparkles"
        case .sessions: return "terminal.fill"
        }
    }

    @MainActor var title: String {
        switch self {
        case .fiveHour: return L(.usageFiveHourLong)
        case .weekly:   return L(.usageWeeklyLong)
        case .opus:     return L(.usageOpusLong)
        case .sessions: return L(.edgeRingSessions)
        }
    }

    /// Nil means "this ring has nothing to say on this Mac right now" — a plan with no
    /// separate Opus allowance, for instance. `UsageDashboardView` applies the same rule
    /// to its own Opus gauge; a ring that always reads 0% would be worse than no ring.
    func progress(usage: UsageSnapshot, workingCount: Int, sessionCount: Int) -> Double? {
        switch self {
        case .fiveHour: return usage.fiveHourPercent
        case .weekly:   return usage.weeklyPercent
        case .opus:     return usage.opusPercent
        case .sessions:
            // Not a limit but an occupancy: how much of what is open is actually busy.
            guard sessionCount > 0 else { return 0 }
            return Double(workingCount) / Double(sessionCount)
        }
    }

    /// Nil when there is no reset to report — no date yet, or a ring that has no window at
    /// all. `UsageSnapshot.countdown` renders an em dash for an unknown date, and "— sonra
    /// sıfırlanır" is not a sentence.
    @MainActor func resetsIn(usage: UsageSnapshot) -> String? {
        let text: String?
        switch self {
        case .fiveHour: text = usage.fiveHourResetsIn
        case .weekly:   text = usage.weeklyResetsIn
        case .opus:     text = usage.opusResetsIn
        case .sessions: text = nil
        }
        guard let text, text != "—" else { return nil }
        return text
    }

    /// The usage rings share the dashboard's colour thresholds. The session ring follows
    /// the app's status colour instead — it is reporting state, not consumption, and a
    /// "green means plenty left" reading would be nonsense on it.
    @MainActor func tint(progress: Double, status: SessionStatus) -> Color {
        switch self {
        case .sessions:
            return status.creatureTint ?? Theme.dim
        default:
            return progress > 0.85 ? Theme.red : (progress > 0.6 ? Theme.amber : Theme.green)
        }
    }

    // MARK: Persistence

    private static let key = "edgeRings"

    /// The rings the user has switched on, filtered down to the ones that have something
    /// to show. Order always follows `allCases`, never the stored order.
    static func enabled(in defaults: UserDefaults = .standard) -> [UsageRingKind] {
        guard let stored = defaults.array(forKey: key) as? [String] else { return Self.defaults }
        let chosen = Set(stored.compactMap(UsageRingKind.init(rawValue:)))
        return allCases.filter(chosen.contains)
    }

    static func setEnabled(_ rings: [UsageRingKind], in defaults: UserDefaults = .standard) {
        defaults.set(allCases.filter(rings.contains).map(\.rawValue), forKey: key)
    }

    /// Rings that can actually be drawn right now: the enabled ones, minus any whose value
    /// is unavailable on this plan.
    static func visible(usage: UsageSnapshot, workingCount: Int, sessionCount: Int,
                        in defaults: UserDefaults = .standard) -> [UsageRingKind] {
        enabled(in: defaults).filter {
            $0.progress(usage: usage, workingCount: workingCount, sessionCount: sessionCount) != nil
        }
    }
}
