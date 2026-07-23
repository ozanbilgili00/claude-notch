import AppKit

/// Side-effecting actions the notch buttons trigger for a session.
@MainActor
enum SessionActions {

    /// Open a terminal at the session's working directory.
    static func openTerminal(cwd: String) {
        guard !cwd.isEmpty else { return }
        let url = URL(fileURLWithPath: cwd)
        // Prefer the user's terminal; fall back to Terminal.app.
        let candidates = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
        let bundleID = candidates.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveal the project directory in Finder.
    static func openProject(cwd: String) {
        guard !cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    /// Copy text (e.g. a log) to the clipboard.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
