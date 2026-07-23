import Foundation

/// Persisted "Always Allow" rules. A rule matches a tool and, for Bash, a command
/// prefix (first word) so approving `npm test` once auto-allows future `npm …` calls
/// without re-prompting. For file/other tools the rule covers the whole tool.
final class PermissionRules {
    private let key = "permissionRules"
    private var rules: Set<String>   // encoded as "tool|signature"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        rules = Set(saved)
    }

    func matches(tool: String, input: [String: Any]) -> Bool {
        rules.contains(Self.signature(tool: tool, input: input))
    }

    func add(tool: String, input: [String: Any]) {
        rules.insert(Self.signature(tool: tool, input: input))
        UserDefaults.standard.set(Array(rules), forKey: key)
    }

    func removeAll() {
        rules.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    var count: Int { rules.count }

    /// "tool|signature" — Bash keys on the first command word; other tools on the tool name.
    private static func signature(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let cmd = input["command"] as? String {
            let firstWord = cmd
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .first.map(String.init) ?? ""
            return "Bash|\(firstWord)"
        }
        return "\(tool)|*"
    }
}
