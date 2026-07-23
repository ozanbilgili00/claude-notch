import Foundation

/// Parsed highlights from one transcript JSONL line. Only the fields the notch needs.
struct TranscriptEvent {
    var model: String?
    var branch: String?
    var addedTokens: Int = 0
    var logLine: String?
    var userPrompt: String?   // a real user prompt (not a tool result)
}

/// Stateless parser for Claude Code transcript lines. Tolerant of unknown/extra fields
/// and of schema drift: anything it doesn't recognize is simply ignored.
enum TranscriptParser {

    static func parse(line: Data) -> TranscriptEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        var event = TranscriptEvent()

        event.branch = obj["gitBranch"] as? String

        let type = obj["type"] as? String
        let message = obj["message"] as? [String: Any]

        if type == "assistant", let message {
            event.model = message["model"] as? String
            if let usage = message["usage"] as? [String: Any] {
                event.addedTokens = tokenCount(usage)
            }
            event.logLine = assistantLog(message)
        } else if type == "user", let message {
            event.logLine = userLog(message)
            // A plain-string user content is a real prompt (tool results are arrays).
            if let text = message["content"] as? String, !text.isEmpty {
                event.userPrompt = firstLine(text)
            }
        }
        return event
    }

    /// Total tokens attributable to one assistant message (input + output + cache).
    private static func tokenCount(_ usage: [String: Any]) -> Int {
        func int(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        return int("input_tokens") + int("output_tokens")
            + int("cache_creation_input_tokens") + int("cache_read_input_tokens")
    }

    /// A concise one-line preview of an assistant message (tool call or first text).
    private static func assistantLog(_ message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                if let input = block["input"] as? [String: Any] {
                    if let cmd = input["command"] as? String { return "$ \(firstLine(cmd))" }
                    if let f = input["file_path"] as? String {
                        return "→ \(name) \((f as NSString).lastPathComponent)"
                    }
                }
                return "→ \(name)"
            case "text":
                if let t = block["text"] as? String, !t.isEmpty { return firstLine(t) }
            default:
                continue
            }
        }
        return nil
    }

    private static func userLog(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return firstLine(s) }
        if let arr = message["content"] as? [[String: Any]] {
            for block in arr where block["type"] as? String == "tool_result" {
                if let c = block["content"] as? String { return firstLine(c) }
            }
        }
        return nil
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
