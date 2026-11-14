import SwiftUI

/// The UI application. Agent-style (no dock icon, LSUIElement); everything lives in the
/// notch — settings included, on a tab of the panel. The `Settings` scene stays empty
/// because `App` needs a scene at all: a preferences *window* is what this app spent two
/// rounds getting rid of.
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
