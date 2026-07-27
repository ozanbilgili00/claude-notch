import Foundation

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
    equal(assistant?.addedTokens, 20, "all four token buckets are summed")
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

group("PermissionPolicy — what gets gated") {
    let rules = PermissionRules()

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

// MARK: - Report

print("")
if failures.isEmpty {
    print("✅ \(passed) checks passed")
    exit(0)
} else {
    print("❌ \(failures.count) failed, \(passed) passed")
    for f in failures { print("   - \(f)") }
    exit(1)
}
