import Foundation

/// One Claude Code session being observed. Value type; the store owns the array.
struct Session: Identifiable, Equatable {
    let id: String                 // Claude Code session_id, or agy conversation id
    /// Which CLI runs this session.
    var agent: Agent = .claude
    /// For Gemini: the gemini-mcp job id when Claude handed this work over.
    var delegatedJob: String?
    var projectName: String        // last path component of cwd
    var cwd: String
    var title: String?             // Claude Code's own session title (transcript `ai-title`)
    var task: String               // the user's latest prompt (the "goal")
    var status: SessionStatus
    var activity: ActivityKind
    var activityDetail: String     // e.g. "npm test — agent-events" / "App.tsx"
    var currentTool: String?       // e.g. "Bash", "Edit", "AskUserQuestion"
    var model: String              // e.g. "claude-fable-5"
    var terminalApp: String?       // e.g. "iTerm2", "Ghostty", "Cursor"
    var branch: String?
    var startedAt: Date
    var lastActivityAt: Date

    // Lines added / removed (the names predate that meaning): for the whole session,
    // and for the current turn, which is what the completion card reports.
    var filesAdded: Int
    var filesRemoved: Int
    var turnAdded = 0
    var turnRemoved = 0
    var tokens: TokenCounts

    var transcriptPath: String?
    var pid: Int32?                // claude CLI process id (from discovery)
    var tty: String?              // controlling terminal, e.g. "/dev/ttys003"
    var logTail: [String]          // recent log lines for preview
    var conversation: [ConversationTurn] = []   // recent turns, built by TranscriptWatcher

    /// Subagents this session has running right now (SubagentStart → SubagentStop).
    var subagents: [Subagent] = []
    /// Between PreCompact and PostCompact: the conversation is being summarised.
    var compacting = false

    var pendingPermission: PermissionRequest?
    var pendingQuestion: Question?
    var completion: Completion?
    var timeline: [TimelineEntry]

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// What the notch calls this session: Claude Code's own title when it has named the
    /// session, otherwise the working directory's name.
    var displayName: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return projectName
    }

    /// Compact "~/Desktop/film · ttys004" subtitle for headers.
    var locationLine: String {
        let home = NSHomeDirectory()
        var path = cwd
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        guard let tty, let name = tty.split(separator: "/").last else { return path }
        return "\(path) · \(name)"
    }

    /// Pretty model name for badges ("claude-opus-5-5" -> "Opus 5.5"). Empty until the
    /// transcript has said which model is running.
    var modelDisplay: String { Session.prettyModel(model) }

    /// Rule-based rather than a lookup table, so a model released after this build
    /// still reads properly: drop the vendor prefix and any 8-digit date stamp,
    /// capitalise the family, and join the version numbers with dots.
    static func prettyModel(_ raw: String) -> String {
        // Gemini's CLI already writes a readable name ("Gemini 4 Argon (Low)").
        if raw.contains(" ") { return raw }
        var parts = raw.lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard !parts.isEmpty else { return "" }
        let words = parts.prefix { !$0.allSatisfy(\.isNumber) }.map { $0.capitalized }
        let numbers = parts.drop { !$0.allSatisfy(\.isNumber) }
        let version = numbers.prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        // Words after the version are kept: "gemini-3.8-flash-high" → "Gemini 3.8 Flash High".
        let tail = numbers.drop { $0.allSatisfy(\.isNumber) }.map { $0.capitalized }
        return (words + (version.isEmpty ? [] : [version]) + tail).joined(separator: " ")
    }

    static func empty(id: String, cwd: String) -> Session {
        let name = (cwd as NSString).lastPathComponent
        return Session(
            id: id, projectName: name.isEmpty ? "session" : name, cwd: cwd, title: nil,
            task: "", status: .idle, activity: .idle, activityDetail: "",
            currentTool: nil, model: "", terminalApp: nil, branch: nil,
            startedAt: Date(), lastActivityAt: Date(),
            filesAdded: 0, filesRemoved: 0, tokens: TokenCounts(),
            transcriptPath: nil, pid: nil, tty: nil, logTail: [], pendingPermission: nil,
            pendingQuestion: nil, completion: nil, timeline: []
        )
    }
}

/// The coding agent behind a session.
enum Agent: String, Equatable {
    case claude      // Claude Code
    case gemini      // Antigravity CLI (`agy`)
}

/// A subagent started by a session (Task / Agent tool).
struct Subagent: Identifiable, Equatable {
    let id: String          // Claude Code's agent_id
    var type: String        // agent_type, e.g. "Explore"; may be empty
    var startedAt: Date
}

/// Summary shown on the "Task Completed" screen.
struct Completion: Equatable {
    var duration: TimeInterval
    var filesAdded: Int
    var filesRemoved: Int
    // A Bool rather than the display text: the badge used to be coloured by searching
    // that text for "pass", so the moment it was translated every badge turned red.
    var testsPassed: Bool?        // nil when the log said nothing about tests
    var succeeded: Bool
    var summary: String
}

struct TimelineEntry: Identifiable, Equatable {
    let id = UUID()
    var time: Date
    var text: String
}
