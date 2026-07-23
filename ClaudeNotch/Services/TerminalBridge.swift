import AppKit

/// Bridges the notch to the real terminal a session runs in. Finds the terminal tab by
/// its tty and can focus it or type a prompt into it (which Claude Code reads as input).
/// Currently targets Terminal.app via AppleScript; unsupported terminals fall back to
/// focusing + copying the prompt to the clipboard.
enum TerminalBridge {

    enum SendResult { case sent, focusedAndCopied, failed }

    /// Bring the session's terminal tab to the front.
    @discardableResult
    static func focus(tty: String?, cwd: String) -> Bool {
        if let tty, runAppleScript(focusScript(tty: tty)) == "ok" { return true }
        // Fallback: open a terminal at the working directory.
        DispatchQueue.main.async { openTerminal(cwd: cwd) }
        return false
    }

    /// Type `prompt` into the session's terminal and submit it (Claude reads it as input).
    static func send(prompt: String, tty: String?, cwd: String) -> SendResult {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed }

        if let tty, runAppleScript(sendScript(tty: tty, prompt: text)) == "ok" {
            return .sent
        }
        // Fallback: copy the prompt and focus the terminal so the user can paste it.
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            openTerminal(cwd: cwd)
        }
        return .focusedAndCopied
    }

    // MARK: AppleScript

    private static func focusScript(tty: String) -> String {
        """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is "\(tty)" then
                  set selected tab of w to t
                  set frontmost of w to true
                  return "ok"
                end if
              end try
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    private static func sendScript(tty: String, prompt: String) -> String {
        let escaped = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is "\(tty)" then
                  set selected tab of w to t
                  set frontmost of w to true
                  do script "\(escaped)" in t
                  return "ok"
                end if
              end try
            end repeat
          end repeat
        end tell
        return "notfound"
        """
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
