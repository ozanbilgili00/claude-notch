import Foundation

/// Translates incoming Claude Code hook events into `SessionStore` mutations, and
/// decides what (if anything) to send back to the hook. Phase 1 is observation-only:
/// every event returns an empty "proceed" reply so Claude Code behaves exactly as
/// usual, while the notch reflects live state. Blocking replies (permissions,
/// questions) build on this in Phases 2–3.
@MainActor
final class HookCoordinator {
    private let store: SessionStore
    private var watchers: [String: TranscriptWatcher] = [:]
    private let rules = PermissionRules()

    /// Continuations for blocked hooks, keyed by request id (tool_use_id).
    private var responders: [String: CheckedContinuation<[String: Any], Never>] = [:]

    /// Start time of the current turn per session (for completion duration).
    private var turnStart: [String: Date] = [:]

    init(store: SessionStore) {
        self.store = store
        store.onPermissionDecision = { [weak self] sessionID, decision in
            self?.resolvePermission(sessionID: sessionID, decision: decision)
        }
        store.onQuestionAnswer = { [weak self] sessionID, choiceIndex in
            self?.resolveQuestion(sessionID: sessionID, choiceIndex: choiceIndex)
        }
    }

    /// Handle one event. Returns the reply dict the server should send to the client.
    /// Blocking events (a gated PreToolUse) suspend here until the user answers.
    func handle(event: String, payload: [String: Any]) async -> [String: Any] {
        let dbg = ProcessInfo.processInfo.environment["NOTCH_DEBUG"]
        if dbg == "1" {
            let sid = sessionID(payload) ?? "?"
            let tool = payload["tool_name"] as? String ?? ""
            fputs("[coord] event=\(event) session=\(sid) tool=\(tool)\n", stderr)
        } else if dbg == "2" {
            // Full-payload dump for schema discovery.
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                ?? Data()
            fputs("[payload] event=\(event) \(String(data: data, encoding: .utf8) ?? "?")\n", stderr)
        }
        ensureSession(payload)

        switch event {
        case "SessionStart":            onSessionStart(payload)
        case "SessionEnd":              onSessionEnd(payload)
        case "UserPromptSubmit":        onPrompt(payload)
        case "PreToolUse":              return await onPreTool(payload)
        case "PostToolUse",
             "PostToolUseFailure":      onPostTool(payload, failed: event == "PostToolUseFailure")
        case "Notification":            onNotification(payload)
        case "Stop", "StopFailure":     onStop(payload, failed: event == "StopFailure")
        default:                        break
        }

        return proceed()
    }

    /// Empty stdout + exit 0 → Claude Code proceeds with its normal behavior.
    private func proceed() -> [String: Any] { ["stdout": "", "exitCode": 0] }

    // Feature toggles (default on). Let the user disable notch interception if a
    // particular Claude Code version doesn't play well with it.
    private func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    private var interceptPermissions: Bool { flag("interceptPermissions") }
    private var interceptQuestions: Bool { flag("interceptQuestions") }

    // MARK: Session lifecycle

    private func ensureSession(_ p: [String: Any]) {
        guard let id = sessionID(p) else { return }
        let cwd = p["cwd"] as? String ?? ""
        if store.session(id) == nil {
            var s = Session.empty(id: id, cwd: cwd)
            s.transcriptPath = p["transcript_path"] as? String
            store.upsert(s)
            startWatcher(for: id, path: s.transcriptPath)
        } else {
            store.update(id) { s in
                if s.transcriptPath == nil, let tp = p["transcript_path"] as? String {
                    s.transcriptPath = tp
                }
            }
            if watchers[id] == nil {
                startWatcher(for: id, path: p["transcript_path"] as? String)
            }
        }
    }

    private func onSessionStart(_ p: [String: Any]) {
        guard let id = sessionID(p) else { return }
        store.update(id) { $0.status = .idle; $0.startedAt = Date() }
    }

    private func onSessionEnd(_ p: [String: Any]) {
        guard let id = sessionID(p) else { return }
        watchers[id]?.stop()
        watchers[id] = nil
        // Unblock any pending hook so the client never hangs past session end.
        if let reqID = store.session(id)?.pendingPermission?.id {
            finish(reqID, reply: ["stdout": "", "exitCode": 0])
        }
        if let reqID = store.session(id)?.pendingQuestion?.id {
            finish(reqID, reply: ["stdout": "", "exitCode": 0])
        }
        // Keep the card briefly as idle, then drop it.
        store.update(id) {
            $0.status = .idle; $0.activity = .idle; $0.currentTool = nil
            $0.pendingPermission = nil; $0.pendingQuestion = nil
        }
        let sid = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            store.remove(sid)
        }
    }

    // MARK: Turn / activity

    private func onPrompt(_ p: [String: Any]) {
        guard let id = sessionID(p) else { return }
        let prompt = (p["prompt"] as? String) ?? (p["user_prompt"] as? String) ?? ""
        turnStart[id] = Date()
        store.update(id) { s in
            // Local slash-command output arrives on this channel too; keep it out.
            if let clean = PromptText.clean(prompt) { s.task = clean }
            s.status = .working
            s.activity = .planning
            s.currentTool = nil
            s.completion = nil
            s.lastActivityAt = Date()
        }
    }

    private func onPreTool(_ p: [String: Any]) async -> [String: Any] {
        guard let id = sessionID(p) else { return proceed() }
        let tool = p["tool_name"] as? String ?? "?"
        let input = p["tool_input"] as? [String: Any] ?? [:]
        let command = input["command"] as? String
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        let mode = p["permission_mode"] as? String ?? "default"

        store.update(id) { s in
            s.currentTool = tool
            s.activity = ActivityKind.from(toolName: tool, command: command)
            s.activityDetail = command ?? file ?? ""
            s.status = (tool == "AskUserQuestion") ? .waiting : .working
            s.lastActivityAt = Date()
            s.timeline.append(TimelineEntry(time: Date(), text: "\(tool) \(s.activityDetail)"))
        }

        let requestID = (p["tool_use_id"] as? String) ?? UUID().uuidString

        // Interactive questions: answer them from the notch (default mode only, so an
        // agent session running in auto/bypass keeps using its own UI). Toggleable.
        if tool == "AskUserQuestion" {
            if interceptQuestions, mode == "default",
               let q = QuestionParser.parse(input: input, id: requestID) {
                return await awaitQuestion(sessionID: id, question: q)
            }
            return proceed()
        }

        // Gate the call if policy says so; otherwise let Claude Code proceed.
        let effectiveMode = interceptPermissions ? mode : "off"
        let classification = PermissionPolicy.classify(tool: tool, input: input, mode: effectiveMode,
                                                       requestID: requestID, rules: rules)
        if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] != nil {
            let gated = { if case .prompt = classification { return "PROMPT" } else { return "pass" } }()
            fputs("[gate] tool=\(tool) mode=\(mode) gated=\(PermissionPolicy.isGated(tool)) -> \(gated)\n", stderr)
        }
        switch classification {
        case .pass:
            return proceed()
        case .prompt(let request):
            return await awaitPermission(sessionID: id, request: request)
        }
    }

    /// Show the permission request and suspend until the user answers (or a safety
    /// timeout elapses, in which case we fall back to Claude Code's normal prompt).
    private func awaitPermission(sessionID id: String, request: PermissionRequest) async -> [String: Any] {
        store.update(id) { s in
            s.pendingPermission = request
            s.status = .waiting
            s.activity = .waiting
        }
        if let s = store.session(id) {
            NotificationService.notify(.needsAttention, session: s,
                                       body: L(.notifPermissionNeeded, request.toolName))
        }

        // Safety net: if unanswered after 5 minutes, stop blocking and let CC prompt.
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            if responders[request.id] != nil {
                finish(request.id, reply: ["stdout": "", "exitCode": 0])
                store.update(id) { if $0.pendingPermission?.id == request.id { $0.pendingPermission = nil } }
            }
        }

        let reply = await withCheckedContinuation { cont in
            responders[request.id] = cont
        }
        timeout.cancel()
        return reply
    }

    /// Show an interactive question and suspend until the user picks a choice (or the
    /// safety timeout elapses, letting Claude Code's own prompt take over).
    private func awaitQuestion(sessionID id: String, question: Question) async -> [String: Any] {
        store.update(id) { s in
            s.pendingQuestion = question
            s.status = .waiting
            s.activity = .waiting
        }
        if let s = store.session(id) {
            NotificationService.notify(.needsAttention, session: s, body: question.prompt)
        }

        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            if responders[question.id] != nil {
                finish(question.id, reply: ["stdout": "", "exitCode": 0])
                store.update(id) { if $0.pendingQuestion?.id == question.id { $0.pendingQuestion = nil } }
            }
        }

        let reply = await withCheckedContinuation { cont in
            responders[question.id] = cont
        }
        timeout.cancel()
        return reply
    }

    /// Called by the UI (via SessionStore) when the user picks an answer (1-based index).
    func resolveQuestion(sessionID: String, choiceIndex: Int) {
        guard let question = store.session(sessionID)?.pendingQuestion else { return }
        let answer = question.choices.first { $0.index == choiceIndex }?.label ?? "\(choiceIndex)"
        store.update(sessionID) { s in
            s.pendingQuestion = nil
            s.status = .working
            s.activity = .idle
        }
        finish(question.id, reply: QuestionParser.reply(answer: answer))
    }

    /// Handle a control message (from the CLI `--resolve`, or future remote control).
    /// Returns true if it acted on a pending request.
    func control(action: String, session: String, decision: String) -> Bool {
        guard action == "resolve" else { return false }
        // If no session given, act on the first blocking one.
        let sid = session.isEmpty ? store.blockingSession?.id : session
        guard let sid else { return false }

        // A numeric decision answers a pending question by choice index.
        if let idx = Int(decision), store.session(sid)?.pendingQuestion != nil {
            resolveQuestion(sessionID: sid, choiceIndex: idx)
            return true
        }
        let map: [String: PermissionDecision] = [
            "allowOnce": .allowOnce, "alwaysAllow": .alwaysAllow, "deny": .deny,
        ]
        guard let d = map[decision], store.session(sid)?.pendingPermission != nil else { return false }
        resolvePermission(sessionID: sid, decision: d)
        return true
    }

    /// Called by the UI (via SessionStore) when the user chooses Allow/Deny.
    func resolvePermission(sessionID: String, decision: PermissionDecision) {
        guard let request = store.session(sessionID)?.pendingPermission else { return }
        if decision == .alwaysAllow {
            rules.add(tool: request.toolName, input: permissionInput(request))
        }
        store.update(sessionID) { s in
            s.pendingPermission = nil
            s.status = .working
            s.activity = .idle
        }
        finish(request.id, reply: PermissionPolicy.reply(for: decision))
    }

    /// Resolve a pending responder exactly once.
    private func finish(_ id: String, reply: [String: Any]) {
        guard let cont = responders.removeValue(forKey: id) else { return }
        cont.resume(returning: reply)
    }

    /// Reconstruct a minimal tool_input for rule matching from a stored request.
    private func permissionInput(_ r: PermissionRequest) -> [String: Any] {
        var input: [String: Any] = [:]
        if let c = r.command { input["command"] = c }
        return input
    }

    private func onPostTool(_ p: [String: Any], failed: Bool) {
        guard let id = sessionID(p) else { return }
        store.update(id) { s in
            s.lastActivityAt = Date()
            if failed { s.status = .error }
        }
    }

    private func onNotification(_ p: [String: Any]) {
        guard let id = sessionID(p) else { return }
        let message = p["message"] as? String ?? ""
        let matcher = p["matcher_type"] as? String ?? ""
        let needsUser = matcher.contains("permission") || matcher.contains("input")
            || message.lowercased().contains("permission")
        store.update(id) { s in
            if needsUser {
                s.status = .waiting
                s.activity = .waiting
                if !message.isEmpty { s.activityDetail = message }
            }
        }
    }

    private func onStop(_ p: [String: Any], failed: Bool) {
        guard let id = sessionID(p) else { return }
        let start = turnStart[id]
        turnStart[id] = nil

        store.update(id) { s in
            s.status = failed ? .error : .idle
            s.activity = .idle
            s.currentTool = nil
            s.lastActivityAt = Date()

            let duration = start.map { Date().timeIntervalSince($0) } ?? 0
            s.completion = Completion(
                duration: duration,
                filesAdded: s.filesAdded,
                filesRemoved: s.filesRemoved,
                testsPassed: testsPassed(from: s.logTail),
                succeeded: !failed,
                summary: failed ? (s.activityDetail.isEmpty ? L(.turnEndedWithError) : s.activityDetail)
                                : (s.task.isEmpty ? "" : s.task)
            )
        }

        if let s = store.session(id) {
            NotificationService.notify(failed ? .failed : .completed, session: s,
                                       body: failed ? L(.notifTaskFailed) : L(.notifTaskCompleted))
        }

        // Success cards auto-dismiss after a few seconds; errors stay until dismissed.
        if !failed {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                store.update(id) { if $0.completion?.succeeded == true { $0.completion = nil } }
            }
        }
    }

    /// Reads pass/fail out of the tail of the log. The keywords stay English because
    /// they're matched against test-runner output, not shown to anyone — the badge text
    /// is looked up separately from the returned Bool.
    private func testsPassed(from log: [String]) -> Bool? {
        for line in log.reversed() {
            let l = line.lowercased()
            if l.contains("fail") && (l.contains("test") || l.contains("passed")) { return false }
            if l.contains("pass") && l.contains("test") { return true }
        }
        return nil
    }

    // MARK: Transcript watcher

    /// Reconcile the store with the set of currently-running sessions found by
    /// `SessionDiscovery`: add ones we didn't know about, drop ones whose process ended.
    func applyDiscovered(_ found: [SessionDiscovery.Found]) {
        let ids = Set(found.map(\.id))

        for f in found {
            if store.session(f.id) == nil {
                var s = Session.empty(id: f.id, cwd: f.cwd)
                let encoded = f.cwd.replacingOccurrences(of: "/", with: "-")
                let path = SessionDiscovery.projectsRoot
                    .appendingPathComponent(encoded)
                    .appendingPathComponent("\(f.id).jsonl").path
                s.transcriptPath = path
                s.pid = f.pid
                s.tty = f.tty
                s.terminalApp = f.terminalApp
                s.status = .idle
                store.upsert(s)
                startWatcher(for: f.id, path: path)
            } else {
                // Keep terminal coordinates fresh on already-tracked sessions.
                store.update(f.id) {
                    $0.pid = f.pid
                    $0.tty = f.tty
                    if let app = f.terminalApp { $0.terminalApp = app }
                }
            }
        }

        // Prune sessions whose process is gone — but never a blocking or freshly-active one.
        let now = Date()
        for s in store.sessions where !ids.contains(s.id) {
            let blocking = s.pendingPermission != nil || s.pendingQuestion != nil || s.completion != nil
            let stale = now.timeIntervalSince(s.lastActivityAt) > 90
            if !blocking && stale {
                watchers[s.id]?.stop()
                watchers[s.id] = nil
                store.remove(s.id)
            }
        }
    }

    private func startWatcher(for id: String, path: String?) {
        guard let path, watchers[id] == nil else { return }
        let watcher = TranscriptWatcher(sessionID: id, path: path, store: store)
        watchers[id] = watcher
        watcher.start()
    }

    // MARK: Helpers

    private func sessionID(_ p: [String: Any]) -> String? {
        (p["session_id"] as? String) ?? (p["sessionId"] as? String)
    }

}
