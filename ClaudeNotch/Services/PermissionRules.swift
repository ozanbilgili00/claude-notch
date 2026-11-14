import Foundation
import Observation

/// Persisted "Always Allow" rules. For Bash a rule is the command's first two words, so
/// approving `git status` does not also wave through `git push --force`; for file and
/// other tools the rule covers the whole tool.
///
/// Rules saved before the two-word change keyed on the first word alone. They are kept
/// — deleting someone's approvals silently would be worse — but stored apart and shown
/// as "broad" in Settings so they can be reviewed and removed.
///
/// A command that chains others (`&&`, `;`, `|`, `$(…)`, backticks) never matches any
/// rule: approving `cd app` must not approve `cd app && rm -rf ~`.
@Observable
final class PermissionRules {
    static let shared = PermissionRules()

    struct Rule: Hashable, Identifiable {
        var tool: String
        var pattern: String      // "git status", or "*" for the whole tool
        var legacy: Bool         // first-word rule from before the two-word change

        var id: String { (legacy ? "legacy|" : "") + "\(tool)|\(pattern)" }
        var coversWholeTool: Bool { pattern == "*" }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "permissionRules.v2"
    private static let legacyKey = "permissionRules"

    private var current: [String]    // "tool|pattern", insertion order kept for display
    private var legacy: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.stringArray(forKey: Self.key) ?? []
        legacy = defaults.stringArray(forKey: Self.legacyKey) ?? []
    }

    // MARK: Matching

    func matches(tool: String, input: [String: Any]) -> Bool {
        let command = input["command"] as? String
        if tool == "Bash", let command, Self.chains(command) { return false }
        if current.contains(Self.signature(tool: tool, input: input)) { return true }
        // Old rules: Bash matched on the first word, other tools already on "*".
        let old = tool == "Bash"
            ? "Bash|\(Self.words(command ?? "").first ?? "")"
            : "\(tool)|*"
        return legacy.contains(old)
    }

    // MARK: Editing

    func add(tool: String, input: [String: Any]) {
        let sig = Self.signature(tool: tool, input: input)
        guard !current.contains(sig) else { return }
        current.append(sig)
        save()
    }

    func remove(_ rule: Rule) {
        let raw = "\(rule.tool)|\(rule.pattern)"
        if rule.legacy { legacy.removeAll { $0 == raw } } else { current.removeAll { $0 == raw } }
        save()
    }

    func removeAll() {
        current.removeAll()
        legacy.removeAll()
        save()
    }

    var count: Int { current.count + legacy.count }

    /// Everything saved, newest last, old broad rules after the rest.
    var all: [Rule] {
        func parse(_ raw: String, legacy: Bool) -> Rule? {
            guard let bar = raw.firstIndex(of: "|") else { return nil }
            return Rule(tool: String(raw[..<bar]), pattern: String(raw[raw.index(after: bar)...]),
                        legacy: legacy && raw.hasPrefix("Bash|"))
        }
        return current.compactMap { parse($0, legacy: false) }
            + legacy.compactMap { parse($0, legacy: true) }
    }

    private func save() {
        defaults.set(current, forKey: Self.key)
        if legacy.isEmpty { defaults.removeObject(forKey: Self.legacyKey) }
        else { defaults.set(legacy, forKey: Self.legacyKey) }
    }

    // MARK: Signatures

    /// "Bash|git status" — the first two words; "Edit|*" for everything else.
    static func signature(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let cmd = input["command"] as? String {
            return "Bash|" + words(cmd).prefix(2).joined(separator: " ")
        }
        return "\(tool)|*"
    }

    private static func words(_ command: String) -> [String] {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }

    /// True when the command runs more than one thing, so its first words don't describe it.
    static func chains(_ command: String) -> Bool {
        ["&&", "||", ";", "|", "$(", "`", "\n"].contains { command.contains($0) }
    }
}
