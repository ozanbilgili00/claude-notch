import Foundation
import CoreAudio

// Tiny assertion harness — no XCTest, because adding a test target means editing
// project.pbxproj by hand, and that is exactly what once cost this project its ⌘R.
// `run-tests.sh` compiles the pure-logic sources together with this file instead.

var passed = 0
var failures: [String] = []

func check(_ condition: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    if condition { passed += 1 }
    else { failures.append("\(what)  (line \(line))") }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
    if actual == expected { passed += 1 }
    else { failures.append("\(what): expected \(expected), got \(actual)  (line \(line))") }
}

func group(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

// MARK: - PromptText

group("PromptText — noise filtering") {
    check(PromptText.isNoise("<local-command-stdout>Set model to Opus 4.8</local-command-stdout>"),
          "local-command-stdout is noise")
    check(PromptText.isNoise("<system-reminder>be nice</system-reminder>"), "system tags are noise")
    check(PromptText.isNoise("Caveat: The messages below were generated…"), "caveats are noise")
    check(PromptText.isNoise("/model"), "bare slash command is noise")
    check(PromptText.isNoise("   \n  "), "blank is noise")
    check(PromptText.isNoise("[Request interrupted by user]"), "interruption notice is noise")

    check(!PromptText.isNoise("faz7ye geç"), "a real prompt is not noise")
    check(!PromptText.isNoise("/tmp/foo diye bir dizin var mı"),
          "a sentence starting with a path is not a slash command")
}

group("PromptText — cleaning") {
    equal(PromptText.clean("faz7ye geç"), "faz7ye geç", "plain prompt survives")
    equal(PromptText.clean("[Image #9] sağ üstteki ses"), "sağ üstteki ses",
          "leading image marker is stripped")
    equal(PromptText.clean("[Image #1] [Image #2] iki resim"), "iki resim",
          "repeated image markers are stripped")
    equal(PromptText.clean("ilk satır\nikinci satır"), "ilk satır", "collapses to first line")
    equal(PromptText.clean("<local-command-stdout>x"), nil, "noise cleans to nil")

    let long = String(repeating: "a", count: 200)
    equal(PromptText.clean(long, limit: 10)?.count, 11, "truncates to limit plus ellipsis")
    check(PromptText.clean(long, limit: 10)?.hasSuffix("…") == true, "truncation adds ellipsis")
}

// MARK: - TranscriptParser

func parse(_ object: [String: Any]) -> TranscriptEvent? {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return TranscriptParser.parse(line: data)
}

group("TranscriptParser — session identity") {
    let title = parse(["type": "ai-title", "aiTitle": "Film analiz et projeyi"])
    equal(title?.aiTitle, "Film analiz et projeyi", "ai-title is read")

    let last = parse(["type": "last-prompt", "lastPrompt": "faz7ye geç"])
    equal(last?.lastPrompt, "faz7ye geç", "last-prompt is read")

    // The whole point of routing last-prompt through PromptText.
    let noisy = parse(["type": "last-prompt", "lastPrompt": "<local-command-stdout>Set model"])
    equal(noisy?.lastPrompt, nil, "noisy last-prompt is rejected")
}

group("TokenTally — one count per API message") {
    var tally = TokenTally()
    let a = TokenCounts(input: 10, output: 5, cacheRead: 100)
    tally.record(id: "msg_1", a)
    tally.record(id: "msg_1", a)                       // second content block, same reply
    equal(tally.total, a, "repeated lines of one reply count once")
    tally.record(id: "msg_1", TokenCounts(input: 10, output: 9, cacheRead: 100))
    equal(tally.total.output, 9, "a later line for the same id replaces, not adds")
    tally.record(id: "msg_2", TokenCounts(output: 1))
    equal(tally.total.output, 10, "a new id adds")
    tally.record(id: nil, TokenCounts(output: 1))
    equal(tally.total.output, 11, "lines without an id still count")
}

group("Session — model names") {
    equal(Session.prettyModel("claude-opus-5-5"), "Opus 5.5", "two-part version gets a dot")
    equal(Session.prettyModel("claude-fable-5-1"), "Fable 5.1", "new family needs no table entry")
    equal(Session.prettyModel("claude-sonnet-5"), "Sonnet 5", "single version number")
    equal(Session.prettyModel("claude-haiku-4-5-20251001"), "Haiku 4.5", "date stamp is dropped")
    equal(Session.prettyModel(""), "", "unknown model reads as empty, hiding the badge")
    equal(Session.empty(id: "x", cwd: "/tmp/p").model, "", "a new session claims no model")
}

group("TokenLedger — day buckets") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 0, minute: 30))!
    var state = LedgerState()
    state.record(id: "a", time: now.addingTimeInterval(-10 * 60), counts: TokenCounts(output: 5))   // 00:20 today
    state.record(id: "b", time: now.addingTimeInterval(-40 * 60), counts: TokenCounts(output: 7))   // 23:50 yesterday
    state.record(id: "c", time: now.addingTimeInterval(-8 * 86400), counts: TokenCounts(output: 100)) // too old
    state.record(id: "a", time: now.addingTimeInterval(-10 * 60), counts: TokenCounts(output: 6))   // same reply again
    let t = state.totals(now: now, calendar: cal)
    equal(t.today.output, 6, "midnight splits today from yesterday; a repeated reply counts once")
    equal(t.week.output, 13, "the week covers seven rolling days, not older")

    let line = #"{"type":"assistant","timestamp":"2026-09-26T21:25:00.123Z","message":{"id":"m1","usage":{"input_tokens":2,"output_tokens":3}}}"#
    state.ingest(line: Data(line.utf8))
    equal(state.totals(now: now, calendar: cal).today.main, 11, "a real transcript line is read, fractional seconds and all")
    state.ingest(line: Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8))
    equal(state.totals(now: now, calendar: cal).today.main, 11, "lines without usage are skipped")
    state.prune(now: now)
    equal(state.totals(now: now, calendar: cal).week.output, 16, "pruning drops only what is out of the window")
}

group("UsageAlerts — once per threshold per window") {
    let reset = Date(timeIntervalSince1970: 1_800_000_000)
    func snap(_ five: Double, resets: Date = reset, weekly: Double = 0.1) -> UsageSnapshot {
        var s = UsageSnapshot.empty
        s.fiveHourPercent = five; s.fiveHourResetsAt = resets
        s.weeklyPercent = weekly; s.weeklyResetsAt = reset.addingTimeInterval(86400 * 3)
        s.isLive = true
        return s
    }
    var fired = Set<String>()
    var r = UsageAlerts.evaluate(previous: snap(0.5), current: snap(0.7), fired: fired)
    equal(r.alerts.count, 0, "below 80 % is quiet")
    r = UsageAlerts.evaluate(previous: snap(0.7), current: snap(0.81), fired: r.fired)
    equal(r.alerts.map(\.kind), [.threshold(80)], "crossing 80 % alerts")
    fired = r.fired
    r = UsageAlerts.evaluate(previous: snap(0.81), current: snap(0.84), fired: fired)
    equal(r.alerts.count, 0, "staying above 80 % does not repeat")
    r = UsageAlerts.evaluate(previous: snap(0.84), current: snap(0.84, resets: reset.addingTimeInterval(40)), fired: fired)
    equal(r.alerts.count, 0, "a reset time drifting by seconds is still the same window")

    let jump = UsageAlerts.evaluate(previous: snap(0.7), current: snap(0.97), fired: [])
    equal(jump.alerts.map(\.kind), [.threshold(95)], "a jump past both thresholds alerts once, at the top")
    equal(UsageAlerts.evaluate(previous: snap(0.97), current: snap(0.98), fired: jump.fired).alerts.count, 0,
          "…and the lower threshold is not announced afterwards")

    let next = reset.addingTimeInterval(5 * 3600)
    let after = UsageAlerts.evaluate(previous: snap(0.9), current: snap(0.05, resets: next), fired: fired)
    equal(after.alerts.map(\.kind), [.reset], "a tight window resetting is announced")
    let calm = UsageAlerts.evaluate(previous: snap(0.4), current: snap(0.02, resets: next), fired: [])
    equal(calm.alerts.count, 0, "an unremarkable window resets silently")
    let again = UsageAlerts.evaluate(previous: snap(0.05, resets: next), current: snap(0.82, resets: next), fired: after.fired)
    equal(again.alerts.map(\.kind), [.threshold(80)], "the next window can warn again")

    var offline = snap(0.99); offline.isLive = false
    equal(UsageAlerts.evaluate(previous: nil, current: offline, fired: []).alerts.count, 0,
          "local estimates never alert")
    var opus = snap(0.1); opus.opusPercent = 0.96; opus.opusResetsAt = reset
    equal(UsageAlerts.evaluate(previous: snap(0.1), current: opus, fired: []).alerts.map(\.window), [.opus],
          "the Opus window is watched when the plan has one")
}

group("LineDelta — +/− from tool input") {
    equal(LineDelta.from(tool: "Edit", input: ["old_string": "a\nb\nc", "new_string": "a\nB\nc\nd"]),
          LineDelta(added: 2, removed: 1), "shared lines cancel, changed and new lines count")
    equal(LineDelta.from(tool: "Write", input: ["content": "x\ny\n"]), LineDelta(added: 2),
          "a written file adds its lines; a trailing newline is not one")
    equal(LineDelta.from(tool: "MultiEdit", input: ["edits": [["old_string": "a", "new_string": "b"],
                                                               ["old_string": "", "new_string": "c"]]]),
          LineDelta(added: 2, removed: 1), "multi-edit sums its edits")
    equal(LineDelta.from(tool: "Bash", input: ["command": "rm x"]), LineDelta(), "other tools change nothing")
}

group("DailyLog — today and trimming") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
    func entry(_ hoursAgo: Double, _ project: String, ok: Bool = true) -> DailyEntry {
        DailyEntry(time: now.addingTimeInterval(-hoursAgo * 3600), project: project,
                   duration: 60, added: 10, removed: 2, succeeded: ok)
    }
    let entries = [entry(1, "notch"), entry(2, "dg9"), entry(3, "notch", ok: false),
                   entry(13, "notch"), entry(24 * 20, "old")]
    let today = DailyLog.summarize(entries, now: now, calendar: cal)
    equal(today.turns, 3, "only turns since midnight count")
    equal(today.failures, 1, "failures are counted")
    equal(today.added, 30, "lines add up")
    equal(today.projects, ["notch", "dg9"], "busiest project first")
    equal(DailyLog.trimmed(entries, now: now, calendar: cal).count, 4, "entries older than 14 days are dropped")
    check(DailyLog.summarize([], now: now).isEmpty, "no turns reads as empty")
}

group("ScreenPicker — which display") {
    let builtIn = ScreenCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), hasNotch: true)
    let external = ScreenCandidate(id: 2, frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440), hasNotch: false)
    let menuOnExternal = [ScreenCandidate(id: 1, frame: CGRect(x: -1728, y: 0, width: 1728, height: 1117), hasNotch: true),
                          ScreenCandidate(id: 2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), hasNotch: false)]
    let both = [builtIn, external]
    let onExternal = CGPoint(x: 2000, y: 500)

    equal(ScreenPicker.pick(.automatic, mode: .notch, candidates: menuOnExternal, pointer: .zero), 1,
          "notch mode prefers the real notch even when the menu bar is elsewhere")
    equal(ScreenPicker.pick(.automatic, mode: .edge, candidates: menuOnExternal, pointer: .zero), 2,
          "edge mode stays with the menu bar")
    equal(ScreenPicker.pick(.pointer, mode: .notch, candidates: both, pointer: onExternal), 2,
          "follow-the-pointer picks the display under it")
    equal(ScreenPicker.pick(.pointer, mode: .notch, candidates: both, pointer: CGPoint(x: -5000, y: 0)), 1,
          "a pointer off every display falls back to automatic")
    equal(ScreenPicker.pick(.display(2), mode: .notch, candidates: both, pointer: .zero), 2, "a chosen display wins")
    equal(ScreenPicker.pick(.display(9), mode: .notch, candidates: both, pointer: .zero), 1,
          "an unplugged choice falls back to automatic")
    equal(ScreenChoice(raw: ScreenChoice.display(42).raw), .display(42), "choice round-trips through defaults")
    equal(ScreenChoice(raw: "garbage"), .automatic, "unknown values read as automatic")
}

group("CompactNumber") {
    equal(CompactNumber.format(950), "950", "under a thousand stays exact")
    equal(CompactNumber.format(12_400), "12.4k", "thousands get one decimal")
    equal(CompactNumber.format(3_000_000), "3M", "a trailing .0 is dropped")
    equal(CompactNumber.format(124_300), "124k", "no decimal above 100")
    equal(CompactNumber.format(1_500_000, decimalComma: true), "1,5M", "Turkish decimal comma")
}

group("TranscriptParser — messages") {
    let assistant = parse([
        "type": "assistant",
        "message": [
            "model": "claude-opus-5",
            "usage": ["input_tokens": 10, "output_tokens": 5,
                      "cache_creation_input_tokens": 2, "cache_read_input_tokens": 3],
            "content": [["type": "text", "text": "Hello there"]],
        ],
    ])
    equal(assistant?.model, "claude-opus-5", "model is read")
    equal(assistant?.usage, TokenCounts(input: 10, output: 5, cacheRead: 3, cacheWrite: 2),
          "token buckets are read separately")
    equal(assistant?.usage?.main, 15, "headline count is fresh input + output only")

    let synthetic = parse(["type": "assistant", "message": ["model": "<synthetic>"]])
    equal(synthetic?.model, nil, "a <synthetic> model stamp is ignored")
    equal(assistant?.assistantText, "Hello there", "assistant prose is extracted")

    let toolUse = parse([
        "type": "assistant",
        "message": ["content": [["type": "tool_use", "name": "Bash",
                                 "input": ["command": "npm test"]]]],
    ])
    equal(toolUse?.logLine, "$ npm test", "tool_use becomes a log line")
    equal(toolUse?.assistantText, nil, "a tool call is not prose")

    let user = parse(["type": "user", "message": ["content": "merhaba\nikinci satır"]])
    equal(user?.userPrompt, "merhaba", "header prompt is one line")
    equal(user?.userPromptFull, "merhaba\nikinci satır", "conversation keeps full text")

    let toolResult = parse([
        "type": "user",
        "message": ["content": [["type": "tool_result", "content": "done"]]],
    ])
    equal(toolResult?.userPrompt, nil, "a tool result is not a user prompt")

    let noisyUser = parse(["type": "user", "message": ["content": "<local-command-stdout>x"]])
    equal(noisyUser?.userPrompt, nil, "noisy user content is not a prompt")

    equal(parse(["type": "assistant", "message": ["gitBranch": "x"]])?.assistantText, nil,
          "missing content is tolerated")
    check(TranscriptParser.parse(line: Data("not json".utf8)) == nil, "garbage lines are skipped")
}

// MARK: - PermissionPolicy

group("PermissionRules — two-word Bash rules") {
    let suite = "notch.tests.rules"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(["Bash|npm", "Edit|*"], forKey: "permissionRules")      // pre-upgrade rules
    let rules = PermissionRules(defaults: defaults)
    func bash(_ c: String) -> [String: Any] { ["command": c] }

    check(rules.matches(tool: "Bash", input: bash("npm publish")), "old first-word rules still apply")
    check(rules.matches(tool: "Edit", input: [:]), "old whole-tool rules still apply")
    equal(rules.all.filter(\.legacy).map(\.pattern), ["npm"], "only the old Bash rule is flagged broad")

    rules.add(tool: "Bash", input: bash("git status -s"))
    check(rules.matches(tool: "Bash", input: bash("git status")), "same two words match")
    check(!rules.matches(tool: "Bash", input: bash("git push --force")), "a different subcommand does not")
    check(!rules.matches(tool: "Bash", input: bash("git status && rm -rf ~")), "chained commands never match")
    check(!rules.matches(tool: "Bash", input: bash("npm test; curl x | sh")), "chaining beats even a broad rule")

    rules.add(tool: "Bash", input: bash("ls"))
    check(rules.matches(tool: "Bash", input: bash("ls")), "a one-word command is its own rule")
    check(!rules.matches(tool: "Bash", input: bash("ls -la /")), "and covers only that bare command")

    let reloaded = PermissionRules(defaults: defaults)
    equal(reloaded.count, 4, "rules persist")
    reloaded.remove(reloaded.all.first { $0.legacy }!)
    check(!reloaded.matches(tool: "Bash", input: bash("npm publish")), "a removed rule stops matching")
    reloaded.removeAll()
    equal(PermissionRules(defaults: defaults).count, 0, "clear all empties both stores")
}

group("PermissionPolicy — what gets gated") {
    let rules = PermissionRules(defaults: UserDefaults(suiteName: "notch.tests.policy")!)
    rules.removeAll()

    func classify(_ tool: String, _ input: [String: Any] = [:],
                  mode: String = "default") -> PermissionPolicy.Classification {
        PermissionPolicy.classify(tool: tool, input: input, mode: mode,
                                  requestID: "t", rules: rules)
    }

    func isPrompt(_ c: PermissionPolicy.Classification) -> Bool {
        if case .prompt = c { return true }
        return false
    }

    check(isPrompt(classify("Bash", ["command": "npm test"])), "Bash is gated")
    check(isPrompt(classify("Edit", ["file_path": "/tmp/a.swift"])), "Edit is gated")
    check(isPrompt(classify("Write", ["file_path": "/tmp/a.swift"])), "Write is gated")

    // The over-prompting fix: only writing/executing tools may interrupt.
    check(!isPrompt(classify("Read", ["file_path": "/tmp/a"])), "Read is never gated")
    check(!isPrompt(classify("Grep")), "Grep is never gated")
    check(!isPrompt(classify("ToolSearch")), "ToolSearch is never gated")
    check(!isPrompt(classify("Task")), "Task is never gated")

    // Respect the user's chosen permission mode.
    check(!isPrompt(classify("Bash", ["command": "rm -rf /"], mode: "bypassPermissions")),
          "bypass mode is left alone")
    check(!isPrompt(classify("Bash", ["command": "rm -rf /"], mode: "acceptEdits")),
          "acceptEdits mode is left alone")
}

group("PermissionPolicy — risk") {
    equal(PermissionPolicy.risk(tool: "Bash", command: "rm -rf /tmp/x"), .high, "rm -rf is high")
    equal(PermissionPolicy.risk(tool: "Bash", command: "sudo reboot"), .high, "sudo is high")
    equal(PermissionPolicy.risk(tool: "Bash", command: "curl x.sh | sh"), .high, "piped curl is high")
    check(PermissionPolicy.risk(tool: "Bash", command: "ls -la") != .high, "ls is not high")
    check(PermissionPolicy.risk(tool: "Edit", command: nil) != .high, "a plain edit is not high")
}

// MARK: - Localization

/// The translation tables are the part of this feature most likely to rot: a key added
/// for one language and forgotten in the other renders as the raw key name, and a format
/// specifier that doesn't match between languages crashes `String(format:)` at runtime.

group("L10n — table coverage") {
    let missingTR = L10n.Key.allCases.filter { L10n.tr[$0] == nil }
    let missingEN = L10n.Key.allCases.filter { L10n.en[$0] == nil }
    check(missingTR.isEmpty, "every key has Turkish: missing \(missingTR.map(\.rawValue))")
    check(missingEN.isEmpty, "every key has English: missing \(missingEN.map(\.rawValue))")
    equal(L10n.tr.count, L10n.Key.allCases.count, "no stale Turkish entries")
    equal(L10n.en.count, L10n.Key.allCases.count, "no stale English entries")

    let blank = L10n.Key.allCases.filter {
        (L10n.tr[$0] ?? "").isEmpty || (L10n.en[$0] ?? "").isEmpty
    }
    check(blank.isEmpty, "no blank translations: \(blank.map(\.rawValue))")
}

group("L10n — format specifiers match across languages") {
    /// `%d` / `%@` in order of appearance. `String(format:)` reads arguments positionally,
    /// so both languages must ask for the same ones in the same order.
    func specifiers(_ s: String) -> [String] {
        var out: [String] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count - 1 {
            if chars[i] == "%" {
                let next = chars[i + 1]
                if next == "%" { i += 2; continue }
                out.append("%\(next)")
                i += 2
                continue
            }
            i += 1
        }
        return out
    }

    for key in L10n.Key.allCases {
        let tr = specifiers(L10n.tr[key] ?? "")
        let en = specifiers(L10n.en[key] ?? "")
        equal(tr, en, "\(key.rawValue) specifiers agree")
    }
}

group("L10n — lookup falls back rather than blanking") {
    equal(L10n.string(.deny, .tr), "Reddet", "Turkish lookup")
    equal(L10n.string(.deny, .en), "Deny", "English lookup")
    // The percent sign leads in Turkish and trails in English.
    equal(L10n.percent(15, .tr), "%15", "Turkish percent")
    equal(L10n.percent(15, .en), "15%", "English percent")
    equal(L10n.decimal(1.5, .tr), "1,50", "Turkish decimal separator")
    equal(L10n.decimal(1.5, .en), "1.50", "English decimal separator")
    equal(L10n.decimal(3, .tr), "3", "whole numbers keep no decimals")
}

group("L10n — model-facing strings stay English") {
    // These go to Claude, not to the user; translating them degrades its behaviour.
    let denyReply = PermissionPolicy.reply(for: .deny)
    let stdout = denyReply["stdout"] as? String ?? ""
    check(stdout.contains("Denied in Claude Notch"), "deny reason is still English")
    let allowReply = PermissionPolicy.reply(for: .allowOnce)
    check((allowReply["stdout"] as? String ?? "").contains("Approved in Claude Notch"),
          "approve reason is still English")
}

// MARK: - Lyrics (LRC)

group("LRC — timestamp parsing") {
    equal(LRC.parseTimestamp("01:23.45"), 83.45, "mm:ss.xx")
    equal(LRC.parseTimestamp("00:31.480"), 31.48, "three-digit fraction")
    equal(LRC.parseTimestamp("10:00.00"), 600.0, "ten minutes")
    equal(LRC.parseTimestamp("00:05,50"), 5.5, "comma fraction is accepted")
    check(LRC.parseTimestamp("ar:Daft Punk") == nil, "metadata tag is not a timestamp")
    check(LRC.parseTimestamp("offset:+500") == nil, "offset tag is not a timestamp")
    check(LRC.parseTimestamp("") == nil, "empty is not a timestamp")
}

group("LRC — file parsing") {
    let file = """
    [ar:Daft Punk]
    [ti:Get Lucky]
    [00:31.48] Like the legend of the phoenix
    [00:35.40] All ends with beginnings
    [00:39.83]
    """
    let lines = LRC.parse(file)
    equal(lines.count, 3, "metadata tags are dropped, lyric lines kept")
    equal(lines[0].text, "Like the legend of the phoenix", "first line text")
    equal(lines[0].time, 31.48, "first line time")
    equal(lines[2].text, "", "an empty line survives as a timed gap")

    // A repeated chorus is written as several tags on one line.
    let repeated = LRC.parse("[00:10.00][01:20.00] We're up all night")
    equal(repeated.count, 2, "multiple timestamps expand to multiple lines")
    equal(repeated[1].time, 80.0, "second copy takes the later time")
    equal(repeated[0].text, repeated[1].text, "both copies carry the same text")

    // Files in the wild are not always in order.
    let unsorted = LRC.parse("[00:20.00] second\n[00:10.00] first")
    equal(unsorted.map(\.text), ["first", "second"], "output is sorted by time")

    // A bracket inside the lyric itself must not be read as a timestamp.
    let bracketed = LRC.parse("[00:05.00] hey [whispered]")
    equal(bracketed.count, 1, "only leading tags count")
    equal(bracketed[0].text, "hey [whispered]", "later brackets stay in the text")

    equal(LRC.parse("").count, 0, "empty file yields nothing")
    equal(LRC.parse("just plain lyrics\nno timestamps").count, 0, "plain text is not synced")
}

group("LRC — active line") {
    let lines = LRC.parse("[00:10.00] a\n[00:20.00] b\n[00:30.00] c")
    check(LRC.activeIndex(lines, at: 0) == nil, "nothing is active before the first line")
    check(LRC.activeIndex(lines, at: 9.9) == nil, "still nothing just before it")
    equal(LRC.activeIndex(lines, at: 10), 0, "exactly on a timestamp activates that line")
    equal(LRC.activeIndex(lines, at: 15), 0, "holds until the next one")
    equal(LRC.activeIndex(lines, at: 20), 1, "advances on time")
    equal(LRC.activeIndex(lines, at: 999), 2, "past the end the last line stays active")
    check(LRC.activeIndex([], at: 5) == nil, "an empty file has no active line")
}

group("Spotify — locale-tolerant numbers") {
    equal(SpotifyService.parseNumber("12.5"), 12.5, "period decimal")
    // AppleScript formats reals with the system separator, so a Turkish Mac says "12,5".
    equal(SpotifyService.parseNumber("12,5"), 12.5, "comma decimal")
    equal(SpotifyService.parseNumber("240000"), 240000, "integer")
    check(SpotifyService.parseNumber("abc") == nil, "garbage is nil")
}

// MARK: - Artwork accent

/// Builds an RGBA buffer from a list of (colour, share) pairs, so a test can say
/// "this cover is 70% dark grey and 30% orange" without hand-writing 1600 pixels.
func buffer(_ parts: [(r: UInt8, g: UInt8, b: UInt8, count: Int)]) -> [UInt8] {
    var data: [UInt8] = []
    for part in parts {
        for _ in 0..<part.count { data.append(contentsOf: [part.r, part.g, part.b, 255]) }
    }
    return data
}

group("Artwork — dominant colour") {
    // The regression this whole algorithm exists for: a cover that is mostly dark with a
    // minority of real colour used to average out to grey and fall back to the app accent.
    check(ArtworkLoader.dominant(in: buffer([(20, 20, 22, 1400), (230, 90, 30, 200)])) != nil,
          "a mostly dark cover still yields its colour")

    check(ArtworkLoader.dominant(in: buffer([(20, 20, 20, 800), (200, 200, 200, 800)])) == nil,
          "a greyscale cover declines")

    check(ArtworkLoader.dominant(in: []) == nil, "an empty buffer declines")

    // Hue is accumulated as a vector; averaging raw values would put the mean of two reds
    // either side of the seam in the middle of the wheel, i.e. cyan.
    let wrapped = ArtworkLoader.hsb(1, 0.05, 0.05).hue
    check(wrapped < 0.02 || wrapped > 0.98, "red sits at the seam of the hue circle")

    let orange = ArtworkLoader.hsb(0.9, 0.5, 0.1)
    check(orange.hue > 0.03 && orange.hue < 0.12, "orange hue lands between red and yellow")
    check(orange.saturation > 0.85, "orange is saturated")

    let grey = ArtworkLoader.hsb(0.5, 0.5, 0.5)
    check(grey.saturation == 0, "grey has no saturation")

    check(ArtworkLoader.clamp(0.1, 0.5, 0.9) == 0.5, "clamp holds the floor")
    check(ArtworkLoader.clamp(1.5, 0.5, 0.9) == 0.9, "clamp holds the ceiling")
}

// MARK: - File shelf

group("Shelf — file references") {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("notch-shelf-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = dir.appendingPathComponent("rapor.txt")
    try? "içerik".write(to: original, atomically: true, encoding: .utf8)

    var item = ShelfItem(url: original)
    item.resolve()
    equal(item.displayName, "rapor.txt", "shows the file name")
    equal(item.fileExtension, "TXT", "extension is the badge text")
    check(!item.isMissing, "an existing file is not missing")

    // The reason the shelf stores a bookmark rather than a path: renaming or moving the
    // file in Finder must not turn the row into a dead entry.
    let moved = dir.appendingPathComponent("rapor-son.txt")
    try? FileManager.default.moveItem(at: original, to: moved)
    item.resolve()
    check(!item.isMissing, "a moved file still resolves")
    equal(item.displayName, "rapor-son.txt", "the row follows the rename")

    // Deleting it is the one case that does mark the row — but the row survives, because
    // "the volume is unplugged" and "I am done with this file" are not the same thing.
    try? FileManager.default.removeItem(at: moved)
    item.resolve()
    check(item.isMissing, "a deleted file is reported missing")

    var broken = ShelfItem(url: dir.appendingPathComponent("hiç-olmadı.txt"))
    broken.resolve()
    check(broken.isMissing, "a file that never existed is missing")
}

// MARK: - Spotify Web API

group("Spotify Web — wire format") {
    func decode(_ json: String) -> Payload.SearchResponse? {
        try? JSONDecoder().decode(Payload.SearchResponse.self, from: Data(json.utf8))
    }

    let full = """
    {"tracks":{"items":[{"id":"1","uri":"spotify:track:1","name":"Rüzgar",
     "duration_ms":193000,"artists":[{"name":"Kalben"}],
     "album":{"name":"Sonsuza Kadar","images":[{"url":"https://i.scdn.co/x.jpg"}]}}]}}
    """
    let track = decode(full)?.tracks.items.first?.track
    equal(track?.name, "Rüzgar", "name decodes")
    equal(track?.artist, "Kalben", "artist decodes")
    equal(track?.duration, 193, "duration converts from milliseconds")
    // The URI is the id we keep, because `play track` takes a URI and nothing else.
    equal(track?.id, "spotify:track:1", "the URI is the identity")

    let manyArtists = """
    {"tracks":{"items":[{"id":"2","uri":"spotify:track:2","name":"Düet",
     "duration_ms":1000,"artists":[{"name":"A"},{"name":"B"}],"album":{"name":"X"}}]}}
    """
    equal(decode(manyArtists)?.tracks.items.first?.track?.artist, "A, B", "artists are joined")

    // A podcast episode rides in the same list and carries none of these fields; it has to
    // drop out rather than render as a nameless row.
    let episode = """
    {"tracks":{"items":[{"uri":"spotify:episode:9","duration_ms":500}]}}
    """
    check(decode(episode)?.tracks.items.first?.track == nil, "an entry with no id is skipped")

    let noArt = """
    {"tracks":{"items":[{"id":"3","uri":"spotify:track:3","name":"Y","duration_ms":0,
     "artists":[],"album":{"name":"Z","images":[]}}]}}
    """
    let bare = decode(noArt)?.tracks.items.first?.track
    check(bare != nil, "a track with no cover still decodes")
    check(bare?.artworkURL == nil, "a missing cover is nil, not a bad URL")
}

group("Spotify Web — PKCE") {
    let verifier = SpotifyAuth.PKCE.makeVerifier()
    check(verifier.count >= 43 && verifier.count <= 128, "verifier length is in Spotify's range")
    check(!verifier.contains("+") && !verifier.contains("/") && !verifier.contains("="),
          "verifier is base64url, not base64")
    check(SpotifyAuth.PKCE.makeVerifier() != verifier, "each verifier is new")

    // RFC 7636's own test vector: the challenge for this verifier is fixed, so this
    // catches a wrong hash or the wrong encoding rather than merely "something changed".
    equal(SpotifyAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
          "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
          "challenge matches the RFC 7636 vector")

    let url = SpotifyAuth.authorizeURL(clientID: "abc", challenge: "ch", state: "st")
    let query = url?.query ?? ""
    check(query.contains("code_challenge_method=S256"), "the challenge method is announced")
    check(query.contains("client_id=abc"), "the client id is sent")
    check(!query.contains("client_secret"), "no secret is ever sent")

    // A reply that doesn't carry our state is a different conversation.
    let good = URL(string: "claudenotch://spotify-login-callback?code=xyz&state=st")!
    equal(SpotifyAuth.code(from: good, expectedState: "st"), "xyz", "the code is read back")
    check(SpotifyAuth.code(from: good, expectedState: "other") == nil,
          "a mismatched state is rejected")

    // A space encoded as "+" decodes to a space on the server, which silently corrupts a
    // token; form bodies must use %20.
    check(SpotifyAuth.encode(["a": "x y"]) == "a=x%20y", "form encoding escapes spaces")
}

group("CoreAudio — system mixer") {
    // These run against the real audio hardware of whatever Mac the suite is on, so they
    // assert shape rather than values: the point is that the property calls are wired up
    // correctly (right scope, right element, right buffer size) and that a device with no
    // settable control is reported as such instead of reading back as silence.
    let output = CoreAudioBridge.defaultDevice(output: true)
    check(output != kAudioObjectUnknown, "there is a default output device")
    check(CoreAudioBridge.name(of: output)?.isEmpty == false, "the device has a name")
    check(CoreAudioBridge.channelCount(output, scope: kAudioObjectPropertyScopeOutput) > 0,
          "the default output device carries output channels")

    let outputs = CoreAudioBridge.devices(scope: kAudioObjectPropertyScopeOutput)
    check(outputs.contains { $0.0 == output }, "the default device is in the output list")
    check(outputs.allSatisfy { !$0.1.isEmpty }, "every listed device is named")

    // Volume is optional — HDMI and optical outputs hand control to the receiver — but if
    // an element is settable the scalar has to read back inside 0…1.
    if CoreAudioBridge.hasVolume(output, output: true) {
        let level = CoreAudioBridge.volume(output, output: true)
        check(level.map { $0 >= 0 && $0 <= 1 } == true, "output volume is a 0…1 scalar")
    } else {
        check(CoreAudioBridge.volume(output, output: true) == nil,
              "a device with no settable control reports no volume rather than zero")
    }

    // Mute is optional too, and the service's fallback (drive the level to zero) hinges
    // on this answer being right rather than assumed.
    if CoreAudioBridge.hasMute(output, output: true) {
        check(CoreAudioBridge.muted(output, output: true) != nil,
              "a device with a mute switch reports its state")
    } else {
        check(true, "this device has no mute switch — the level fallback applies")
    }
    check(CoreAudioBridge.hasMute(kAudioObjectUnknown, output: true) == false,
          "an unknown device has no mute switch")
    check(CoreAudioBridge.name(of: kAudioObjectUnknown) == nil,
          "an unknown device has no name")
    check(CoreAudioBridge.volume(kAudioObjectUnknown, output: true) == nil,
          "an unknown device has no volume")
    check(CoreAudioBridge.volumeElements.first == kAudioObjectPropertyElementMain,
          "the master element is tried before the per-channel ones")

    // The per-app mixer is built from this list, so it has to be self-consistent: every
    // entry reports a live pid and claims to be running output.
    let processes = CoreAudioBridge.audioProcesses()
    check(processes.allSatisfy { $0.pid > 0 }, "every audio process has a real pid")
    // The list deliberately includes processes that are silent right now: an app muted by
    // one of our own taps stops reporting output, and dropping it would tear that tap down.
    check(processes.allSatisfy { $0.isPlaying == CoreAudioBridge.isRunningOutput($0.objectID) },
          "each entry reports its own playing state faithfully")
    check(Set(processes.map(\.objectID)).count == processes.count,
          "no process is listed twice")
    check(CoreAudioBridge.processPID(kAudioObjectUnknown) == nil,
          "an unknown object has no pid")
}

group("Mixer — gain table") {
    // The table is read from a real-time audio thread, so its safety has to come from the
    // accessors themselves: no bounds check up there, no lock, no allocation.
    let table = GainTable(capacity: 4)
    equal(table[0], 1, "gains start transparent")
    table[2] = 0.25
    equal(table[2], 0.25, "a gain round-trips")

    table[1] = 5
    equal(table[1], 1, "a gain above one is clamped")
    table[3] = -2
    equal(table[3], 0, "a negative gain is clamped to silence")

    // Out-of-range access must be inert rather than fatal: the index comes from the audio
    // buffer count, which the device decides, not us.
    table[99] = 0.5
    equal(table[99], 1, "an index past the end reads as transparent")
    equal(table[-1], 1, "a negative index reads as transparent")

    check(ProcessTapMixer.capacity >= 4 && ProcessTapMixer.capacity <= 16,
          "the channel count stays small on purpose")
}

group("Edge dock — geometry") {
    // A screen 900pt tall whose menu bar takes the top 25.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visibleTop: CGFloat = 875

    // Height follows the ring count, and an empty dock is still a grip to grab.
    let two = EdgeGeometry.dockHeight(ringCount: 2)
    let three = EdgeGeometry.dockHeight(ringCount: 3)
    check(three > two, "each ring makes the dock taller")
    equal(three - two, EdgeGeometry.ringSlot, "by exactly one slot")
    check(EdgeGeometry.dockHeight(ringCount: 0) >= EdgeGeometry.gripHeight,
          "an empty dock is still grabbable")
    // Switching every ring off must still leave the status head: it is the one thing in
    // the dock that says whether anything is working or waiting on an answer.
    check(EdgeGeometry.dockHeight(ringCount: 0)
            >= EdgeGeometry.gripHeight + EdgeGeometry.statusHeight,
          "an empty dock still shows the session status")
    check(EdgeGeometry.ringCenterY(index: 0, ringCount: 2)
            > EdgeGeometry.gripHeight + EdgeGeometry.statusHeight,
          "the first ring starts below the status head")
    // Both ends of the dock have to clear the concave fillets, or the ring captions are
    // printed outside the black — which is what put the weekly percentage off the bottom.
    check(EdgeGeometry.ringCenterY(index: 0, ringCount: 2) - EdgeGeometry.ringSlot / 2
            >= EdgeGeometry.flare,
          "the first ring clears the top fillet")
    let lastBottom = EdgeGeometry.ringCenterY(index: 1, ringCount: 2) + EdgeGeometry.ringSlot / 2
    check(EdgeGeometry.dockHeight(ringCount: 2) - lastBottom >= EdgeGeometry.flare,
          "the last ring clears the bottom fillet")
    check(EdgeGeometry.dockHeight(ringCount: -3) == EdgeGeometry.dockHeight(ringCount: 0),
          "a negative count is treated as empty rather than inverting the dock")

    // Dragging can never push the dock off the screen at either end.
    let low = EdgeGeometry.clampedOffset(-500, visibleTop: visibleTop, screen: screen, ringCount: 3)
    equal(low, 0, "the dock cannot be dragged above the menu bar")
    let high = EdgeGeometry.clampedOffset(9_000, visibleTop: visibleTop, screen: screen, ringCount: 3)
    equal(high + three, visibleTop - screen.minY, "nor past the bottom of the screen")
    let centred = EdgeGeometry.centeredOffset(visibleTop: visibleTop, screen: screen, ringCount: 3)
    equal(centred * 2 + three, visibleTop - screen.minY, "the starting offset centres it")

    // A dock taller than the space it has left must still resolve to something valid.
    let tiny = CGRect(x: 0, y: 0, width: 1440, height: 80)
    equal(EdgeGeometry.clampedOffset(40, visibleTop: 70, screen: tiny, ringCount: 8), 0,
          "a dock taller than the screen pins to the top instead of going negative")

    // The window hugs the right edge, with the dock's own bleed hanging past it.
    let size = EdgeGeometry.windowSize(ringCount: 3)
    let origin = EdgeGeometry.windowOrigin(screen: screen, visibleTop: visibleTop,
                                           offset: 100, ringCount: 3)
    equal(origin.x + size.width, screen.maxX + EdgeGeometry.bleed,
          "the window's right edge clears the screen edge by the bleed")
    check(size.width > EdgeGeometry.panelSize.width,
          "the window leaves room for the panel beside the dock")

    // The dock lands exactly `offset` below the visible top, whatever the window height.
    let dockTopInWindow = (size.height - three) / 2
    let dockTopOnScreen = origin.y + size.height - dockTopInWindow
    check(abs(dockTopOnScreen - (visibleTop - 100)) < 0.001,
          "the dock sits exactly the saved offset below the menu bar")

    // The panel is centred on the dock only while that keeps it on screen. Dragging the
    // dock to either end used to carry the panel off with it — the header ended up above
    // the menu bar — so the panel is clamped to the visible area instead.
    func panelTop(offset: CGFloat) -> (top: CGFloat, windowTop: CGFloat) {
        let origin = EdgeGeometry.windowOrigin(screen: screen, visibleTop: visibleTop,
                                               offset: offset, ringCount: 3)
        let windowTop = origin.y + size.height
        return (EdgeGeometry.panelTop(windowTop: windowTop, windowHeight: size.height,
                                      visibleTop: visibleTop, visibleBottom: screen.minY),
                windowTop)
    }

    let middle = panelTop(offset: centred)
    equal(middle.top, (size.height - EdgeGeometry.panelSize.height) / 2,
          "with room on both sides the panel stays centred on the dock")

    let atTop = panelTop(offset: 0)
    check(atTop.windowTop - atTop.top <= visibleTop + 0.001,
          "with the dock at the top the panel's own top stays below the menu bar")
    let atBottom = panelTop(offset: 9_000)
    check(atBottom.windowTop - atBottom.top - EdgeGeometry.panelSize.height >= screen.minY - 0.001,
          "with the dock at the bottom the panel's bottom stays on screen")

    // A screen too short to hold the panel at all: pin to the top rather than resolving to
    // a range with no valid answer.
    let shortTop = EdgeGeometry.panelTop(windowTop: 300, windowHeight: 408,
                                         visibleTop: 280, visibleBottom: 0)
    equal(shortTop, 20, "on a screen shorter than the panel it pins under the ceiling")
}

group("Edge dock — bubble placement") {
    let ringCount = 3
    let windowHeight: CGFloat = 500
    let dockTop: CGFloat = 120
    let bubbleHeight: CGFloat = 96

    // The tail has to land on the ring's own centre — the ring position and the tail
    // position come from one function precisely so they cannot drift apart.
    for index in 0..<ringCount {
        let placement = EdgeGeometry.bubblePlacement(
            ringIndex: index, ringCount: ringCount, bubbleHeight: bubbleHeight,
            windowHeight: windowHeight, dockTopInWindow: dockTop)
        let ringY = EdgeGeometry.ringCenterY(index: index, ringCount: ringCount)
        check(abs((placement.top + placement.tailY) - ringY) < 0.001,
              "the tail points at ring \(index)")
    }

    // A bubble that would hang off the top of the window is pushed back in, and the tail
    // stays inside the card rather than following the ring out of it.
    let cramped = EdgeGeometry.bubblePlacement(
        ringIndex: 0, ringCount: ringCount, bubbleHeight: 400,
        windowHeight: windowHeight, dockTopInWindow: 10)
    check(cramped.top + 10 >= -0.001, "an oversized bubble is pushed back inside the window")
    check(cramped.tailY >= 0 && cramped.tailY <= 400, "and its tail stays on the card")

    // Out-of-range indices are clamped, not trusted: the ring list can change underfoot.
    equal(EdgeGeometry.ringCenterY(index: 99, ringCount: ringCount),
          EdgeGeometry.ringCenterY(index: ringCount - 1, ringCount: ringCount),
          "an index past the end clamps to the last ring")
    equal(EdgeGeometry.ringCenterY(index: -4, ringCount: ringCount),
          EdgeGeometry.ringCenterY(index: 0, ringCount: ringCount),
          "a negative index clamps to the first")
}

group("Edge dock — ring selection") {
    let defaults = UserDefaults(suiteName: "ClaudeNotchTests.rings")!
    defaults.removePersistentDomain(forName: "ClaudeNotchTests.rings")

    equal(UsageRingKind.enabled(in: defaults), UsageRingKind.defaults,
          "an untouched install shows the two windows every plan has")

    // Order is the enum's, never the order the user switched them on: a dock that
    // reshuffles itself between launches is unreadable at a glance.
    UsageRingKind.setEnabled([.sessions, .fiveHour], in: defaults)
    equal(UsageRingKind.enabled(in: defaults), [.fiveHour, .sessions],
          "rings keep a fixed order regardless of how they were stored")

    UsageRingKind.setEnabled([], in: defaults)
    check(UsageRingKind.enabled(in: defaults).isEmpty,
          "switching everything off really means none — not a fallback to the defaults")

    // A window the plan doesn't have never reaches the dock.
    UsageRingKind.setEnabled(UsageRingKind.allCases, in: defaults)
    var usage = UsageSnapshot.empty
    usage.fiveHourPercent = 0.4
    usage.weeklyPercent = 0.1
    let withoutOpus = UsageRingKind.visible(usage: usage, workingCount: 0, sessionCount: 0,
                                            in: defaults)
    check(!withoutOpus.contains(.opus), "no Opus allowance, no Opus ring")
    usage.opusPercent = 0.2
    let withOpus = UsageRingKind.visible(usage: usage, workingCount: 0, sessionCount: 0,
                                         in: defaults)
    check(withOpus.contains(.opus), "a plan that reports one gets the ring")

    // The sessions ring reports occupancy, and an empty Mac must not divide by zero.
    equal(UsageRingKind.sessions.progress(usage: usage, workingCount: 0, sessionCount: 0), 0,
          "no sessions reads as empty rather than crashing")
    equal(UsageRingKind.sessions.progress(usage: usage, workingCount: 2, sessionCount: 4), 0.5,
          "half the open sessions working is half a ring")

    defaults.removePersistentDomain(forName: "ClaudeNotchTests.rings")
}

// MARK: - Report

// MARK: - Gemini (agy)

func gstep(_ object: [String: Any]) -> GeminiStep? {
    GeminiStep.parse(line: try! JSONSerialization.data(withJSONObject: object))
}

group("Gemini — transcript steps") {
    let prompt = gstep(["type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE",
                        "content": "<USER_REQUEST>\nselam\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 4 Argon (Low). No need to comment.\n</USER_SETTINGS_CHANGE>"])
    equal(prompt, .prompt(text: "selam", model: "Gemini 4 Argon (Low)"), "request text and model change")

    let delegated = gstep(["type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE",
                           "content": "<USER_REQUEST>\n/plan ÇALIŞMA KURALLARI (başsız mod):\n- kural\n\nGÖREV:\nKodu incele\n</USER_REQUEST>"])
    equal(delegated, .prompt(text: "Kodu incele", model: nil), "gemini-mcp rules are skipped")
    equal(GeminiText.request("<USER_REQUEST>\n/goal bitir şunu\n</USER_REQUEST>"), "bitir şunu",
          "a leading slash command is dropped")

    let response = gstep(["type": "PLANNER_RESPONSE", "source": "MODEL", "status": "DONE",
                          "input_tokens": 100, "output_tokens": 20, "cache_read_tokens": 500,
                          "tool_calls": [["name": "run_command",
                                          "args": ["CommandLine": "\"npm test\"", "Cwd": "\"/tmp\""]]]])
    equal(response, .response(text: "", tools: [GeminiToolCall(name: "run_command",
                                                                 args: ["CommandLine": "npm test", "Cwd": "/tmp"])],
                              tokens: TokenCounts(input: 100, output: 20, cacheRead: 500)),
          "tool args are JSON-decoded, tokens split")

    equal(gstep(["type": "GENERIC", "source": "MODEL", "status": "DONE"]), .toolResult(failed: false), "tool result")
    equal(gstep(["type": "GENERIC", "source": "MODEL", "status": "ERROR"]), .toolResult(failed: true), "failed tool")
    equal(gstep(["type": "GENERIC", "source": "MODEL", "status": "RUNNING"]), .backgroundStarted, "background task")
    equal(gstep(["type": "SYSTEM_MESSAGE", "source": "SYSTEM", "status": "DONE"]), .systemMessage, "system message")
    equal(gstep(["type": "ERROR_MESSAGE", "source": "SYSTEM", "status": "DONE"]), .apiError, "API error")
    equal(gstep(["type": "CHECKPOINT", "source": "SYSTEM", "status": "DONE"]), .checkpoint, "compaction checkpoint")
    check(GeminiStep.parse(line: Data("not json".utf8)) == nil, "junk is ignored")
    equal(GeminiText.unquote("plain"), "plain", "an unquoted value stays")
    equal(gstep(["type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE",
                 "content": "<USER_REQUEST>\n/goal\n</USER_REQUEST>"]),
          .prompt(text: "", model: nil), "a bare slash command starts a turn with no task text")
}

group("Gemini — turn state") {
    let t0 = Date(timeIntervalSince1970: 1000)
    func call(_ name: String, _ args: [String: String] = [:]) -> GeminiToolCall { GeminiToolCall(name: name, args: args) }
    func reply(_ text: String = "", _ tools: [GeminiToolCall] = []) -> GeminiStep {
        .response(text: text, tools: tools, tokens: TokenCounts())
    }

    var turn = GeminiTurn()
    equal(turn.apply(.prompt(text: "x", model: nil), at: t0), .started, "a prompt starts a turn")
    check(turn.working && turn.activity == .planning, "thinking until the first tool")

    _ = turn.apply(reply("", [call("run_command", ["CommandLine": "npm test"])]), at: t0)
    equal(turn.activity, .running, "a test command reads as running tests")
    equal(turn.detail, "npm test", "the command is the detail")
    _ = turn.apply(.toolResult(failed: false), at: t0)

    _ = turn.apply(reply("", [call("view_file", ["AbsolutePath": "/a/b/App.swift"])]), at: t0)
    equal(turn.activity, .reading, "view_file reads")
    equal(turn.detail, "App.swift", "the file name is the detail")
    _ = turn.apply(.toolResult(failed: false), at: t0)

    _ = turn.apply(reply("", [call("replace_file_content", ["TargetContent": "a\nb", "ReplacementContent": "a\nc\nd"]),
                              call("write_to_file", ["CodeContent": "x\ny"])]), at: t0)
    equal(turn.activity, .editing, "edits read as editing")
    _ = turn.apply(.toolResult(failed: false), at: t0)
    _ = turn.apply(.toolResult(failed: true), at: t0)
    equal(turn.added, 2, "only the edit that succeeded counts its lines")
    equal(turn.removed, 1, "removed lines of the successful edit")
    equal(turn.failedTools, 1, "the failed write is counted as a failure")

    equal(turn.apply(reply(""), at: t0), nil, "an empty reply is a retry, not the end")
    check(turn.working, "still working after an empty reply")

    equal(turn.apply(reply("Bitti."), at: t0), .ended(startedAt: t0, added: 2, removed: 1),
          "a plain answer ends the turn with its totals")
    check(!turn.working && turn.activity == .idle, "idle after the turn")

    // Background task: the plain answer while it runs does not end the turn.
    var bg = GeminiTurn()
    _ = bg.apply(.prompt(text: "x", model: nil), at: t0)
    _ = bg.apply(reply("", [call("run_command", ["CommandLine": "sleep 60"])]), at: t0)
    _ = bg.apply(.backgroundStarted, at: t0)
    equal(bg.apply(reply("Bitince bakarım."), at: t0), nil, "not over while a background task is out")
    check(bg.working, "keeps working")
    equal(bg.activity, .running, "shown as running")
    equal(bg.apply(.systemMessage, at: t0), nil, "the task reporting back continues the turn")
    check(bg.apply(reply("Tamam, bitti."), at: t0) != nil, "the next plain answer ends it")
    equal(bg.apply(.systemMessage, at: t0), .started, "a late system message picks the work back up")

    var ask = GeminiTurn()
    _ = ask.apply(.prompt(text: "x", model: nil), at: t0)
    _ = ask.apply(reply("", [call("ask_question")]), at: t0)
    equal(ask.activity, .waiting, "ask_question waits on the user")

    var resumed = GeminiTurn()
    equal(resumed.apply(reply("", [call("view_file", ["AbsolutePath": "/x"])]), at: t0), .started,
          "joining mid-turn starts it")
}

group("Gemini — discovery") {
    let lsof = "p123\nfcwd\nn/Users/o/proj\nftxt\nn/Users/o/.local/bin/agy\nf78u\nn/Users/o/.gemini/antigravity-cli/presence/45ca37ee-ece1-4a5a-b114-0e4c8fffb004.lock\n"
    let open = GeminiDiscovery.openFiles(lsof)
    equal(open?.cwd, "/Users/o/proj", "cwd from lsof")
    equal(open?.conversation, "45ca37ee-ece1-4a5a-b114-0e4c8fffb004", "conversation from the presence lock")
    check(GeminiDiscovery.openFiles("p1\nf3r\nn/x\n")?.conversation == nil, "no lock, no conversation")

    let root = "/Users/o/.cache/gemini-mcp/jobs"
    equal(GeminiDiscovery.jobID(forWorkspace: root + "/gmv7wow3jn3m/ws", jobsRoot: root), "gmv7wow3jn3m", "job workspace")
    equal(GeminiDiscovery.jobID(forWorkspace: root + "/gmv7wow3jn3m/ws/apps/web", jobsRoot: root), "gmv7wow3jn3m",
          "a folder inside the job workspace")
    equal(GeminiDiscovery.jobID(forWorkspace: root + "/gmv7wow3jn3m", jobsRoot: root), nil, "the job folder itself is not a workspace")
    equal(GeminiDiscovery.jobID(forWorkspace: "/Users/o/proj", jobsRoot: root), nil, "an ordinary project")

    equal(GeminiDiscovery.taskLine("ÇALIŞMA KURALLARI:\n- a\n\nGÖREV:\n\nKodu incele\nayrıntı"), "Kodu incele",
          "task line after the rules")
    equal(GeminiDiscovery.taskLine("  Tek satır  "), "Tek satır", "plain prompt")

    equal(Session.prettyModel("Gemini 4 Argon (Low)"), "Gemini 4 Argon (Low)", "agy's readable name is kept")
    equal(Session.prettyModel("gemini-3.8-flash-high"), "Gemini 3.8 Flash High", "a job's model id reads well")
    equal(Session.empty(id: "x", cwd: "/p").agent, .claude, "sessions are Claude unless discovered as Gemini")
}

print("")
if failures.isEmpty {
    print("✅ \(passed) checks passed")
    exit(0)
} else {
    print("❌ \(failures.count) failed, \(passed) passed")
    for f in failures { print("   - \(f)") }
    exit(1)
}
