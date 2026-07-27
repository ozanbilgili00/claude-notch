import Foundation

/// Helpers for deciding what counts as a *real* user prompt.
///
/// Claude Code feeds several non-prompt things through the same channel as typed
/// prompts: local slash-command output (`/model`, `/compact` …), caveat banners, hook
/// injections and system tags. Those must never become a session's title or its
/// "You:" line, otherwise the notch shows things like
/// `<local-command-stdout>Set model to Opus 4.8…` as the user's last prompt.
enum PromptText {

    /// True when the text is machinery rather than something the user typed.
    static func isNoise(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        // Any XML-ish wrapper: <local-command-stdout>, <command-name>, <system-reminder>,
        // <task-notification>, <local-command-caveat>…
        if s.hasPrefix("<") { return true }
        if s.hasPrefix("Caveat:") { return true }
        if s.hasPrefix("[Request interrupted") { return true }
        // A bare slash command is a client-side command, not a prompt.
        if s.hasPrefix("/"), !s.contains(" "), s.count < 40 { return true }
        return false
    }

    /// A sanitized single-line version of a prompt, or nil when it's noise.
    /// Strips any leading `[Image #n]` markers so the text starts with real words.
    static func clean(_ raw: String, limit: Int = 160) -> String? {
        guard !isNoise(raw) else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let r = s.range(of: #"^\[Image( #\d+)?[^\]]*\]\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Collapse to one line for badges/headers; the expanded view re-reads the full text.
        let line = s.split(whereSeparator: \.isNewline)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? s
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
