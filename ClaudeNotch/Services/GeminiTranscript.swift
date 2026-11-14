import Foundation

/// A tool call from a Gemini (`agy`) transcript. `agy` stores every argument as a JSON
/// encoded string (`"CommandLine": "\"npm test\""`); `args` holds them decoded.
struct GeminiToolCall: Equatable {
    var name: String
    var args: [String: String]
}

/// One line of an Antigravity CLI transcript (`brain/<id>/.system_generated/logs/
/// transcript.jsonl`), reduced to what the notch shows. Pure, so it is testable without
/// a running `agy`.
///
/// The transcript is the only source: `agy` hooks run synchronously inside its agent
/// loop, so observing through them would put the notch in Gemini's critical path for
/// no gain while the notch only watches.
enum GeminiStep: Equatable {
    /// The user's request. `text` is empty for a bare slash command (`/goal`), which
    /// still starts a turn but says nothing worth showing as the task. `model` is set
    /// when the same input switched the model.
    case prompt(text: String, model: String?)
    /// A model reply: its text and the tools it called (none = a plain answer).
    case response(text: String, tools: [GeminiToolCall], tokens: TokenCounts)
    /// The result of one tool call, in the order the calls were made.
    case toolResult(failed: Bool)
    /// A tool moved to the background; the turn isn't over until it reports back.
    case backgroundStarted
    /// A system message re-entering the loop — how background tasks report back.
    case systemMessage
    /// An API error; `agy` retries on its own.
    case apiError
    /// The conversation was compacted and resumes from a summary.
    case checkpoint

    static func parse(line: Data) -> GeminiStep? {
        guard let r = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = r["type"] as? String else { return nil }
        let status = r["status"] as? String ?? ""
        let content = r["content"] as? String ?? ""

        switch type {
        case "USER_INPUT":
            return .prompt(text: GeminiText.request(content) ?? "", model: GeminiText.modelChange(content))
        case "PLANNER_RESPONSE":
            let calls = (r["tool_calls"] as? [[String: Any]] ?? []).compactMap(toolCall)
            let tokens = TokenCounts(input: r["input_tokens"] as? Int ?? 0,
                                     output: r["output_tokens"] as? Int ?? 0,
                                     cacheRead: r["cache_read_tokens"] as? Int ?? 0)
            return .response(text: content.trimmingCharacters(in: .whitespacesAndNewlines),
                             tools: calls, tokens: tokens)
        case "SYSTEM_MESSAGE":
            return .systemMessage
        case "ERROR_MESSAGE":
            return .apiError
        case "CHECKPOINT":
            return .checkpoint
        default:
            // Tool output lines are typed GENERIC (or after the tool, e.g. VIEW_FILE).
            guard r["source"] as? String == "MODEL" else { return nil }
            if status == "RUNNING" { return .backgroundStarted }
            return .toolResult(failed: status == "ERROR")
        }
    }

    private static func toolCall(_ raw: [String: Any]) -> GeminiToolCall? {
        guard let name = raw["name"] as? String else { return nil }
        var args: [String: String] = [:]
        for (key, value) in raw["args"] as? [String: Any] ?? [:] {
            if let s = value as? String { args[key] = GeminiText.unquote(s) }
            else { args[key] = "\(value)" }
        }
        return GeminiToolCall(name: name, args: args)
    }
}

/// Text helpers for `agy` transcripts.
enum GeminiText {
    /// The user's words out of a USER_INPUT step: the `<USER_REQUEST>` block, with the
    /// working rules gemini-mcp puts ahead of a delegated task ("…\nGÖREV:\n<task>")
    /// and a leading slash command (`/plan`) dropped.
    static func request(_ content: String) -> String? {
        var text = content
        if let open = text.range(of: "<USER_REQUEST>") {
            text = String(text[open.upperBound...])
            if let close = text.range(of: "</USER_REQUEST>") { text = String(text[..<close.lowerBound]) }
        }
        if let task = text.range(of: "GÖREV:\n") { text = String(text[task.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") {
            guard let space = text.firstIndex(where: { $0 == " " || $0 == "\n" }) else { return nil }
            text = String(text[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    /// "The user changed setting `Model Selection` from X to Gemini 4 Argon (Low). …"
    static func modelChange(_ content: String) -> String? {
        guard let key = content.range(of: "`Model Selection` from ") else { return nil }
        let rest = content[key.upperBound...]
        guard let to = rest.range(of: " to ") else { return nil }
        let tail = rest[to.upperBound...]
        let end = tail.range(of: ". ")?.lowerBound ?? tail.firstIndex(of: "\n") ?? tail.endIndex
        let model = tail[..<end].trimmingCharacters(in: .whitespacesAndNewlines.union(["."]))
        return model.isEmpty ? nil : model
    }

    /// `"\"npm test\""` → `npm test`; anything that isn't a JSON string stays as it is.
    static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), let data = s.data(using: .utf8),
              let decoded = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
        else { return s }
        return decoded
    }
}

/// The state of a Gemini turn, folded step by step from the transcript.
///
/// A reply without tool calls usually ends the turn — but not while a background task is
/// still out: Gemini then says "I'll update when it finishes" and the task's report
/// arrives later as a system message, so the turn stays open until that has happened.
struct GeminiTurn: Equatable {
    var working = false
    var activity: ActivityKind = .idle
    var detail = ""
    var tool: String?
    var startedAt: Date?
    var added = 0
    var removed = 0
    var failedTools = 0

    private var background = 0
    /// Line deltas of tool calls whose results haven't arrived, oldest first. A failed
    /// edit changed nothing, so a delta only counts once its result says it succeeded.
    private var pending: [LineDelta] = []

    enum Outcome: Equatable {
        case started
        case ended(startedAt: Date?, added: Int, removed: Int)
    }

    /// Apply one step; returns what changed at turn level, if anything.
    mutating func apply(_ step: GeminiStep, at now: Date) -> Outcome? {
        switch step {
        case .prompt:
            self = GeminiTurn()
            working = true
            activity = .planning
            startedAt = now
            return .started

        case .response(let text, let tools, _):
            if let last = tools.last {
                let started = !working
                working = true
                tool = last.name
                activity = Self.activity(for: last)
                detail = Self.detail(for: last)
                pending += tools.map(Self.delta)
                if started { startedAt = startedAt ?? now; return .started }
                return nil
            }
            // An empty reply is an API hiccup that `agy` retries; it ends nothing.
            guard !text.isEmpty, working else { return nil }
            if background > 0 {
                activity = .running
                tool = nil
                return nil
            }
            return finish()

        case .toolResult(let failed):
            let delta = pending.isEmpty ? LineDelta() : pending.removeFirst()
            if failed { failedTools += 1 } else { added += delta.added; removed += delta.removed }
            return nil

        case .backgroundStarted:
            background += 1
            if !pending.isEmpty { pending.removeFirst() }
            return nil

        case .systemMessage:
            if background > 0 { background -= 1 }
            guard !working else { return nil }
            // A report after the turn ended picks the work back up.
            working = true
            activity = .planning
            startedAt = now
            return .started

        case .apiError, .checkpoint:
            return nil
        }
    }

    private mutating func finish() -> Outcome {
        let outcome = Outcome.ended(startedAt: startedAt, added: added, removed: removed)
        working = false
        activity = .idle
        tool = nil
        detail = ""
        pending = []
        return outcome
    }

    // MARK: Tool mapping

    static func activity(for call: GeminiToolCall) -> ActivityKind {
        switch call.name {
        case "run_command":
            return ActivityKind.from(toolName: "Bash", command: call.args["CommandLine"])
        case "view_file", "view_file_outline", "view_code_item":
            return .reading
        case "grep_search", "find_by_name", "list_dir", "codebase_search",
             "search_web", "read_url_content":
            return .searching
        case "replace_file_content", "multi_replace_file_content", "write_to_file":
            return .editing
        case "ask_question":
            return .waiting
        default:
            return .shell
        }
    }

    /// What the row prints next to the verb: the command, the file, or `agy`'s own
    /// one-line summary of the call.
    static func detail(for call: GeminiToolCall) -> String {
        let a = call.args
        if let command = a["CommandLine"] { return command }
        if let path = a["AbsolutePath"] ?? a["TargetFile"] { return (path as NSString).lastPathComponent }
        if let url = a["Url"] { return url }
        if let query = a["query"] ?? a["Query"] { return query }
        return a["toolSummary"] ?? call.name
    }

    static func delta(_ call: GeminiToolCall) -> LineDelta {
        let a = call.args
        switch call.name {
        case "replace_file_content":
            return LineDelta.edit(old: a["TargetContent"], new: a["ReplacementContent"])
        case "write_to_file":
            return LineDelta.edit(old: nil, new: a["CodeContent"])
        default:
            return LineDelta()
        }
    }
}
