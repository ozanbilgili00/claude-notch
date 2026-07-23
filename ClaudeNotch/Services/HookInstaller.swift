import Foundation

/// Installs/removes the observer hooks in ~/.claude/settings.json, preserving every
/// other setting the user already has. Idempotent: our entries are identified by the
/// app binary path and replaced on each install, never duplicated.
enum HookInstaller {

    /// Events we register. Tool events get an empty matcher (match all tools).
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Notification", "Stop", "StopFailure",
    ]

    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// Substring that uniquely identifies our hook commands.
    private static let marker = "ClaudeNotch.app/Contents/MacOS/ClaudeNotch"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var binaryPath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    static func isInstalled() -> Bool {
        guard let root = readSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { entry in
                commandsIn(entry).contains { $0.contains(marker) }
            } ?? false
        }
    }

    // MARK: Install / uninstall

    static func install() throws {
        var root = readSettings() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let bin = binaryPath

        for event in events {
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.removeAll { entry in commandsIn(entry).contains { $0.contains(marker) } }

            let hook: [String: Any] = [
                "type": "command",
                "command": "\"\(bin)\" --hook \(event)",
                "timeout": 600,
            ]
            var entry: [String: Any] = ["hooks": [hook]]
            if toolEvents.contains(event) { entry["matcher"] = "" }
            arr.append(entry)
            hooks[event] = arr
        }

        root["hooks"] = hooks
        try writeSettings(root)
    }

    static func uninstall() throws {
        guard var root = readSettings(),
              var hooks = root["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll { entry in commandsIn(entry).contains { $0.contains(marker) } }
            if arr.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = arr }
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        try writeSettings(root)
    }

    // MARK: File I/O

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func commandsIn(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }
}
