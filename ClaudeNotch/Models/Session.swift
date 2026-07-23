import Foundation

/// One Claude Code session being observed. Value type; the store owns the array.
struct Session: Identifiable, Equatable {
    let id: String                 // Claude Code session_id
    var projectName: String        // last path component of cwd
    var cwd: String
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

    var filesAdded: Int
    var filesRemoved: Int
    var sessionTokens: Int

    var transcriptPath: String?
    var pid: Int32?                // claude CLI process id (from discovery)
    var tty: String?              // controlling terminal, e.g. "/dev/ttys003"
    var logTail: [String]          // recent log lines for preview

    var pendingPermission: PermissionRequest?
    var pendingQuestion: Question?
    var completion: Completion?
    var timeline: [TimelineEntry]

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Pretty model name for badges ("claude-fable-5" -> "Fable 5").
    var modelDisplay: String { Session.prettyModel(model) }

    static func prettyModel(_ raw: String) -> String {
        let map: [String: String] = [
            "claude-opus-4-8": "Opus 4.8",
            "claude-fable-5": "Fable 5",
            "claude-sonnet-5": "Sonnet 5",
            "claude-haiku-4-5-20251001": "Haiku 4.5",
        ]
        if let m = map[raw] { return m }
        // Generic cleanup: drop vendor prefix, title-case.
        let stripped = raw.replacingOccurrences(of: "claude-", with: "")
        return stripped.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    static func empty(id: String, cwd: String) -> Session {
        let name = (cwd as NSString).lastPathComponent
        return Session(
            id: id, projectName: name.isEmpty ? "session" : name, cwd: cwd,
            task: "", status: .idle, activity: .idle, activityDetail: "",
            currentTool: nil, model: "claude-opus-4-8", terminalApp: nil, branch: nil,
            startedAt: Date(), lastActivityAt: Date(),
            filesAdded: 0, filesRemoved: 0, sessionTokens: 0,
            transcriptPath: nil, pid: nil, tty: nil, logTail: [], pendingPermission: nil,
            pendingQuestion: nil, completion: nil, timeline: []
        )
    }
}

/// Summary shown on the "Task Completed" screen.
struct Completion: Equatable {
    var duration: TimeInterval
    var filesAdded: Int
    var filesRemoved: Int
    var testsStatus: String?      // "passing" / "failing" / nil
    var succeeded: Bool
    var summary: String
}

struct TimelineEntry: Identifiable, Equatable {
    let id = UUID()
    var time: Date
    var text: String
}
