import SwiftUI

/// The UI application. Agent-style (no dock icon, LSUIElement); everything lives in the
/// notch and the menu bar. A Settings scene provides the preferences window.
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}
