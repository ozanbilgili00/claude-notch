import AppKit

/// Bridges the notch to the real terminal a session runs in. Finds the terminal tab by
/// its tty and can focus it or type a prompt into it (which Claude Code reads as input).
///
/// Terminal.app and iTerm2 both expose their sessions' ttys to AppleScript, so those get
/// real scripted input. Everything else (Ghostty, Alacritty, kitty, …) has no scripting
/// interface for this, so those fall back to focusing the app and putting the prompt on
/// the clipboard — and `SendResult` says which happened so the UI can be honest about it.
enum TerminalBridge {

    enum SendResult {
        case sent
        /// The terminal can't be scripted; the prompt is on the clipboard instead.
        case focusedAndCopied(app: String?)
        case failed
    }

    /// Terminals we can drive, keyed by the name `SessionDiscovery` reports.
    private enum Dialect {
        case terminalApp, iTerm2

        static func to(_ app: String?) -> Dialect? {
            switch app {
            case "Terminal": return .terminalApp
            case "iTerm2":   return .iTerm2
            default:         return nil
            }
        }
    }

    /// Bring the session's terminal tab to the front.
    @discardableResult
    static func focus(tty: String?, cwd: String, app: String? = nil) -> Bool {
        let dialects: [Dialect] = Dialect.to(app).map { [$0] } ?? [.terminalApp, .iTerm2]
        if let tty {
            for dialect in dialects
            where runAppleScript(script(dialect, tty: tty, prompt: nil)) == "ok" {
                return true
            }
        }
        // Fallback: open a terminal at the working directory.
        DispatchQueue.main.async { openTerminal(cwd: cwd) }
        return false
    }

    /// Type `prompt` into the session's terminal and submit it (Claude reads it as input).
    static func send(prompt: String, tty: String?, cwd: String, app: String? = nil) -> SendResult {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed }

        // Try the detected terminal; if detection failed, Terminal.app is the safe guess.
        let dialects: [Dialect] = Dialect.to(app).map { [$0] } ?? [.terminalApp, .iTerm2]
        if let tty {
            for dialect in dialects
            where runAppleScript(script(dialect, tty: tty, prompt: text)) == "ok" {
                return .sent
            }
        }

        // Fallback: copy the prompt and bring the terminal forward so the user can paste.
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)

            let running = app.flatMap { name in
                NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == name }
            }
            if let running { running.activate() } else { openTerminal(cwd: cwd) }
        }
        return .focusedAndCopied(app: app)
    }

    // MARK: AppleScript

    /// One script per dialect. With `prompt == nil` it only focuses the tab.
    private static func script(_ dialect: Dialect, tty: String, prompt: String?) -> String {
        let escaped = prompt.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"")
        }

        switch dialect {
        case .terminalApp:
            let action = escaped.map { "do script \"\($0)\" in t" } ?? ""
            return """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if (tty of t) is "\(tty)" then
                      set selected tab of w to t
                      set frontmost of w to true
                      \(action)
                      return "ok"
                    end if
                  end try
                end repeat
              end repeat
            end tell
            return "notfound"
            """

        case .iTerm2:
            // iTerm2's tty lives on the session, one level below tabs.
            let action = escaped.map { "write text \"\($0)\"" } ?? ""
            return """
            tell application "iTerm2"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    try
                      if (tty of s) is "\(tty)" then
                        select w
                        select t
                        tell s
                          select
                          \(action)
                        end tell
                        return "ok"
                      end if
                    end try
                  end repeat
                end repeat
              end repeat
            end tell
            return "notfound"
            """
        }
    }

    /// Runs an AppleScript source and returns its trimmed string result (or nil on error).
    /// Uses osascript so the one-time Automation consent is attributed to this app.
    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openTerminal(cwd: String) {
        guard !cwd.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }
}
