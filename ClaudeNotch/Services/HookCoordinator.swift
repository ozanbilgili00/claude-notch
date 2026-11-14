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
    private var geminiWatchers: [String: GeminiWatcher] = [:]
    private let rules = PermissionRules.shared

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
        case "SubagentStart":           onSubagentStart(payload)
        case "SubagentStop":            onSubagentStop(payload)
        case "PreCompact":              onCompact(payload, starting: true)
        case "PostCompact":             onCompact(payload, starting: false)
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
            s.compacting = false
            s.turnAdded = 0
            s.turnRemoved = 0
            s.lastActivityAt = Date()
        }
    }

    // MARK: Subagents and compaction

    private func onSubagentStart(_ p: [String: Any]) {
        guard let id = sessionID(p), let agent = p["agent_id"] as? String else { return }
        let type = p["agent_type"] as? String ?? ""
        store.update(id) { s in
            guard !s.subagents.contains(where: { $0.id == agent }) else { return }
            s.subagents.append(Subagent(id: agent, type: type, startedAt: Date()))
            s.lastActivityAt = Date()
        }
    }

    private func onSubagentStop(_ p: [String: Any]) {
        guard let id = sessionID(p), let agent = p["agent_id"] as? String else { return }
        store.update(id) { s in
            s.subagents.removeAll { $0.id == agent }
            s.lastActivityAt = Date()
        }
    }

    /// PreCompact fires for both `/compact` and auto-compaction mid-turn. A manual one
    /// happens between turns, so the session reads as working only while it runs; an
    /// automatic one leaves the turn's own state to carry on afterwards.
    private func onCompact(_ p: [String: Any], starting: Bool) {
        guard let id = sessionID(p) else { return }
        let inTurn = turnStart[id] != nil
        store.update(id) { s in
            s.compacting = starting
            s.lastActivityAt = Date()
            if starting {
                s.status = .working
                s.activity = .compacting
            } else if s.activity == .compacting {
                s.activity = inTurn ? .planning : .idle
                if !inTurn { s.status = .idle }
            }
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
            store.signal(.attention, session: id)
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
            store.signal(.attention, session: id)
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
        let tool = p["tool_name"] as? String ?? ""
        let delta = failed ? LineDelta()
            : LineDelta.from(tool: tool, input: p["tool_input"] as? [String: Any] ?? [:])
        store.update(id) { s in
            s.lastActivityAt = Date()
            if failed { s.status = .error }
            s.filesAdded += delta.added
            s.filesRemoved += delta.removed
            s.turnAdded += delta.added
            s.turnRemoved += delta.removed
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
        completeTurn(id, failed: failed, start: start)
    }

    /// End a turn: the completion card, the hop, the notification and the daily log.
    /// Shared by Claude's Stop hook and the end of a Gemini turn in its transcript.
    private func completeTurn(_ id: String, failed: Bool, start: Date?) {
        store.update(id) { s in
            s.status = failed ? .error : .idle
            s.activity = .idle
            s.currentTool = nil
            // A turn that ends has no subagents or compaction left, even if a matching
            // Stop hook never arrived for one of them.
            s.subagents = []
            s.compacting = false
            s.lastActivityAt = Date()

            let duration = start.map { Date().timeIntervalSince($0) } ?? 0
            s.completion = Completion(
                duration: duration,
                filesAdded: s.turnAdded,
                filesRemoved: s.turnRemoved,
                testsPassed: testsPassed(from: s.logTail),
                succeeded: !failed,
                summary: failed ? (s.activityDetail.isEmpty ? L(.turnEndedWithError) : s.activityDetail)
                                : (s.task.isEmpty ? "" : s.task)
            )
        }

        store.signal(failed ? .failed : .completed, session: id)
        if start != nil, let s = store.session(id), let c = s.completion {
            DailyLog.shared.record(DailyEntry(time: Date(), project: s.projectName, duration: c.duration,
                                              added: c.filesAdded, removed: c.filesRemoved,
                                              succeeded: c.succeeded))
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
    func applyDiscovered(_ found: [SessionDiscovery.Found], gemini: [GeminiDiscovery.Found] = []) {
        let ids = Set(found.map(\.id)).union(gemini.map(\.id))
        applyGemini(gemini)

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
                geminiWatchers[s.id]?.stop()
                geminiWatchers[s.id] = nil
                store.remove(s.id)
            }
        }
    }

    // MARK: Gemini

    /// Sessions of the Antigravity CLI. They have no hooks into the notch: discovery
    /// finds them, and their transcript drives everything else (see `GeminiWatcher`).
    private func applyGemini(_ found: [GeminiDiscovery.Found]) {
        // Switched off in Settings: clear them now rather than waiting for the prune.
        guard UserDefaults.standard.geminiSessionsEnabled else {
            for s in store.sessions where s.agent == .gemini {
                geminiWatchers[s.id]?.stop()
                geminiWatchers[s.id] = nil
                store.remove(s.id)
            }
            return
        }
        for f in found {
            if store.session(f.id) == nil {
                var s = Session.empty(id: f.id, cwd: f.cwd)
                s.agent = .gemini
                s.delegatedJob = f.job?.id
                s.transcriptPath = f.transcriptPath
                s.model = f.job?.model ?? GeminiDiscovery.defaultModel() ?? ""
                if let task = f.job?.task { s.task = task }
                s.pid = f.pid
                s.tty = f.tty
                s.terminalApp = f.terminalApp
                store.upsert(s)
            } else {
                store.update(f.id) {
                    $0.pid = f.pid
                    $0.tty = f.tty
                    if let app = f.terminalApp { $0.terminalApp = app }
                }
            }
            if let watcher = geminiWatchers[f.id] {
                watcher.poke()
            } else {
                let watcher = GeminiWatcher(sessionID: f.id, path: f.transcriptPath) { [weak self] id, snap, outcomes, live in
                    self?.applyGemini(id, snap, outcomes: outcomes, live: live)
                }
                geminiWatchers[f.id] = watcher
                watcher.start()
            }
        }
    }

    private func applyGemini(_ id: String, _ snap: GeminiSnapshot,
                             outcomes: [GeminiTurn.Outcome], live: Bool) {
        guard let before = store.session(id) else { return }
        let turn = snap.turn
        store.update(id) { s in
            // A delegated job's prompt is wrapped in working rules; the job folder's
            // task line is the better title, so the transcript only fills a blank.
            if let task = snap.task, s.delegatedJob == nil || s.task.isEmpty { s.task = task }
            if let model = snap.model { s.model = model }
            s.tokens = snap.tokens
            s.conversation = snap.conversation
            s.turnAdded = turn.added
            s.turnRemoved = turn.removed
            s.currentTool = turn.tool
            if turn.working {
                s.status = turn.activity == .waiting ? .waiting : .working
                s.activity = turn.activity
                s.activityDetail = turn.detail
                s.lastActivityAt = Date()
            } else if s.status == .working || s.status == .waiting {
                s.status = .idle
                s.activity = .idle
            }
        }

        for outcome in outcomes {
            switch outcome {
            case .started:
                store.update(id) { $0.completion = nil; $0.lastActivityAt = Date() }
            case .ended(let start, let added, let removed):
                store.update(id) {
                    $0.filesAdded += added
                    $0.filesRemoved += removed
                }
                completeTurn(id, failed: false, start: start)
            }
        }
        // Gemini asking a question (`ask_question`) is the one wait the transcript shows.
        if live, before.status != .waiting, let s = store.session(id), s.status == .waiting {
            store.signal(.attention, session: id)
            NotificationService.notify(.needsAttention, session: s, body: L(.notifGeminiQuestion))
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
