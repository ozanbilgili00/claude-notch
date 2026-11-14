import Foundation

/// Typed access to the handful of preferences that non-SwiftUI code needs to read.
///
/// `@AppStorage` handles the views; services and the view model can't use it. The catch
/// is that `UserDefaults.bool(forKey:)` returns false for a key that was never written,
/// which is wrong for the switches that default to *on* — hence the explicit
/// `object(forKey:)` check on those.
extension UserDefaults {

    /// Notch closes itself when the pointer leaves. Default on.
    var autoCollapse: Bool { boolDefaultingTrue("autoCollapse") }

    /// Post macOS notifications alongside the alert sound. Default on.
    var notificationsEnabled: Bool { boolDefaultingTrue("notifications") }

    /// Light sweeps and nudges on the notch / dock when something happens. The creature's
    /// own reactions are not affected — they are part of how it shows state.
    var eventAnimationsEnabled: Bool { boolDefaultingTrue("eventAnimations") }

    /// Heads-up at 80 % / 95 % of a usage window and when a tight window resets.
    var usageAlertsEnabled: Bool { boolDefaultingTrue("usageAlerts") }

    /// Show Gemini (Antigravity CLI) sessions next to Claude's. Default on.
    var geminiSessionsEnabled: Bool { boolDefaultingTrue("geminiSessions") }

    /// Silence every alert sound and banner. Default off.
    var muteSounds: Bool { bool(forKey: "muteSounds") }

    /// Which layout the app wears: the panel hanging from the notch, or the dock against
    /// the right-hand screen edge. One or the other, never both.
    var dockMode: DockMode {
        DockMode(rawValue: string(forKey: "dockMode") ?? "") ?? .notch
    }

    /// Per-app volume through Core Audio process taps. Default **on** — it is the whole
    /// point of the mixer. The switch stays because an app that is turned down has its
    /// audio routed through Claude Notch, and anyone who would rather not have that
    /// should be able to say so.
    var appVolumeTaps: Bool { boolDefaultingTrue("appVolumeTaps") }

    /// Denser session rows: title + activity only. Default off.
    var compactMode: Bool { bool(forKey: "compactMode") }

    private func boolDefaultingTrue(_ key: String) -> Bool {
        object(forKey: key) as? Bool ?? true
    }
}

/// The two layouts. Stored as a string so a future third one doesn't renumber the others.
enum DockMode: String, CaseIterable {
    case notch
    case edge
}
