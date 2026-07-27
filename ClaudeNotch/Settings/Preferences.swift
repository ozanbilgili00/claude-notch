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

    /// Silence every alert sound and banner. Default off.
    var muteSounds: Bool { bool(forKey: "muteSounds") }

    /// Denser session rows: title + activity only. Default off.
    var compactMode: Bool { bool(forKey: "compactMode") }

    private func boolDefaultingTrue(_ key: String) -> Bool {
        object(forKey: key) as? Bool ?? true
    }
}
