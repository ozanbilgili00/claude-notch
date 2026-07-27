import Foundation

/// Sample sessions used in Xcode previews and (optionally) during Phase 0 bring-up,
/// so the notch UI can be developed before the live hook pipeline is wired.
enum MockData {

    @MainActor
    static func store() -> SessionStore {
        let s = SessionStore()
        s.sessions = sessions
        s.usage = usage
        s.selectedID = sessions.first?.id
        return s
    }

    static let usage = UsageSnapshot(
        fiveHourPercent: 0.09, fiveHourResetsIn: "4h10m",
        weeklyPercent: 0.09, weeklyResetsIn: "6d12h",
        sessionTokens: 128_400, todayTokens: 1_240_000, weekTokens: 8_900_000,
        isLive: true
    )

    static let sessions: [Session] = [
        {
            var s = Session.empty(id: "s1", cwd: "/Users/ozan/dev/agent-runtime")
            s.projectName = "agent-runtime"
            s.title = "Trace duplicate event dispatches"
            s.tty = "/dev/ttys003"
            s.task = "Trace the agent event pipeline and remove duplicate dispatches"
            s.status = .working
            s.activity = .shell
            s.activityDetail = "npm test — agent-events"
            s.currentTool = "Bash"
            s.model = "claude-fable-5"
            s.terminalApp = "iTerm2"
            s.branch = "main"
            s.filesAdded = 42; s.filesRemoved = 12
            s.sessionTokens = 128_400
            s.startedAt = Date().addingTimeInterval(-16 * 60)
            s.logTail = [
                "> agent-events@1.0.0 test",
                "PASS  src/pipeline/dispatch.test.ts",
                "PASS  src/pipeline/dedupe.test.ts",
                "Tests: 24 passed, 24 total",
            ]
            if ProcessInfo.processInfo.environment["NOTCH_MOCK_DONE"] == "1" {
                s.completion = Completion(duration: 254, filesAdded: 42, filesRemoved: 12,
                                          testsStatus: "tests passing", succeeded: true,
                                          summary: "Removed duplicate dispatches in the event pipeline")
            }
            return s
        }(),
        {
            var s = Session.empty(id: "s2", cwd: "/Users/ozan/dev/desktop-app")
            s.projectName = "desktop-app"
            s.title = "Polish multi-agent session panel"
            s.tty = "/dev/ttys004"
            s.task = "Polish the multi-agent session panel for release"
            s.status = .waiting
            s.activity = .waiting
            s.currentTool = "AskUserQuestion"
            s.model = "claude-fable-5"
            s.terminalApp = "Cursor"
            s.branch = "release/1.2"
            s.startedAt = Date().addingTimeInterval(-11 * 60)
            s.pendingQuestion = Question(
                id: "q1", header: "Theme",
                prompt: "Which theme should the new dashboard default to?",
                choices: [
                    .init(index: 1, label: "Dark", detail: "Matches the terminal aesthetic"),
                    .init(index: 2, label: "Light", detail: "Better for daytime use"),
                    .init(index: 3, label: "System", detail: "Follow macOS appearance"),
                ]
            )
            return s
        }(),
        {
            var s = Session.empty(id: "s3", cwd: "/Users/ozan/dev/vibe-island")
            s.projectName = "vibe-island"
            s.title = "Deterministic terminal routing"
            s.tty = "/dev/ttys005"
            s.task = "Make terminal routing deterministic across splits"
            s.status = .working
            s.activity = .editing
            s.activityDetail = "router/session.ts"
            s.currentTool = "Edit"
            s.model = "claude-opus-4-8"
            s.terminalApp = "Ghostty"
            s.branch = "main"
            s.filesAdded = 8; s.filesRemoved = 3
            s.startedAt = Date().addingTimeInterval(-4 * 60)
            return s
        }(),
    ]

    /// A permission request to preview the Allow / Deny screen.
    static var samplePermission: PermissionRequest {
        PermissionRequest(
            id: "p1", toolName: "Edit", title: "Edit", reason: nil, risk: .low,
            command: nil, filePath: "src/components/App.tsx",
            diff: [
                .init(kind: .removed, oldNumber: 1, newNumber: nil, text: "const theme = 'light'"),
                .init(kind: .removed, oldNumber: 2, newNumber: nil, text: "const fontSize = 14"),
                .init(kind: .added, oldNumber: nil, newNumber: 1, text: "const theme = isDark ? 'dark' : 'light'"),
                .init(kind: .added, oldNumber: nil, newNumber: 2, text: "const fontSize = settings.fontSize ?? 14"),
            ]
        )
    }
}
