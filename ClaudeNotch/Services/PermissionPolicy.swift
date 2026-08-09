import Foundation

/// Decides whether a tool call should silently proceed or be surfaced in the notch for
/// approval, builds the `PermissionRequest` shown to the user, and produces the JSON a
/// PreToolUse hook must print to allow/deny.
enum PermissionPolicy {

    /// Tools we gate for approval. Deliberately a small, explicit allowlist of
    /// write/execute tools — everything else (Read, Grep, ToolSearch, Task, WebFetch,
    /// MCP tools, …) is left to Claude Code's own permission handling, so the notch
    /// only prompts for the operations that actually matter and never over-asks.
    static let gatedTools: Set<String> = [
        "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit",
    ]

    static func isGated(_ tool: String) -> Bool { gatedTools.contains(tool) }

    enum Classification {
        case pass                       // observe only, let Claude Code proceed
        case prompt(PermissionRequest)  // block and ask in the notch
    }

    /// Classify a PreToolUse event. Only gates when the session is in `default`
    /// permission mode; other modes mean the user chose to bypass prompting.
    static func classify(tool: String, input: [String: Any], mode: String,
                         requestID: String, rules: PermissionRules) -> Classification {
        guard mode == "default", isGated(tool) else { return .pass }
        if rules.matches(tool: tool, input: input) { return .pass }
        return .prompt(makeRequest(tool: tool, input: input, requestID: requestID))
    }

    // MARK: Building the request

    static func makeRequest(tool: String, input: [String: Any], requestID: String) -> PermissionRequest {
        let command = input["command"] as? String
        let filePath = input["file_path"] as? String
        let diff = buildDiff(tool: tool, input: input)
        return PermissionRequest(
            id: requestID,
            toolName: tool,
            titleKey: titleKey(for: tool),
            reason: input["description"] as? String,
            risk: risk(tool: tool, command: command),
            command: command,
            filePath: filePath.map { ($0 as NSString).lastPathComponent } ?? filePath,
            diff: diff
        )
    }

    /// Which heading the dialog shows. The tool names switched on here are protocol
    /// identifiers and stay as they are; nil falls back to showing the tool name itself.
    private static func titleKey(for tool: String) -> L10n.Key? {
        switch tool {
        case "Bash": return .permTitleRunCommand
        case "Edit", "MultiEdit": return .permTitleEdit
        case "Write": return .permTitleWriteFile
        case "NotebookEdit": return .permTitleEditNotebook
        case "WebFetch": return .permTitleFetchURL
        default: return tool.hasPrefix("mcp__") ? .permTitleMCPTool : nil
        }
    }

    private static let dangerous = [
        "rm -rf", "rm -fr", "sudo ", ":(){", "mkfs", "dd if=", "> /dev/",
        "curl", "wget", "--force", "chmod -R 777", "killall", "shutdown",
        "> /etc", "diskutil", "eraseDisk",
    ]

    static func risk(tool: String, command: String?) -> PermissionRequest.RiskLevel {
        guard tool == "Bash", let c = command?.lowercased() else {
            return tool == "Write" ? .medium : .low
        }
        // Piping a download into a shell is the classic high-risk pattern.
        if (c.contains("curl") || c.contains("wget")) && c.contains("| sh") { return .high }
        for token in dangerous where c.contains(token) {
            if token == "curl" || token == "wget" { continue } // only high when piped to sh
            return .high
        }
        return .medium
    }

    // MARK: Diff

    private static func buildDiff(tool: String, input: [String: Any]) -> [DiffLine] {
        switch tool {
        case "Edit":
            return diffLines(old: input["old_string"] as? String,
                             new: input["new_string"] as? String)
        case "Write":
            return diffLines(old: nil, new: input["content"] as? String)
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]] else { return [] }
            return edits.flatMap {
                diffLines(old: $0["old_string"] as? String, new: $0["new_string"] as? String)
            }
        default:
            return []
        }
    }

    /// Simple removed-then-added diff (matches the reference screenshot), capped for the notch.
    private static func diffLines(old: String?, new: String?, cap: Int = 12) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldNo = 1, newNo = 1
        if let old, !old.isEmpty {
            for l in old.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(DiffLine(kind: .removed, oldNumber: oldNo, newNumber: nil, text: String(l)))
                oldNo += 1
            }
        }
        if let new, !new.isEmpty {
            for l in new.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNo, text: String(l)))
                newNo += 1
            }
        }
        if lines.count > cap {
            lines = Array(lines.prefix(cap))
            lines.append(DiffLine(kind: .context, oldNumber: nil, newNumber: nil, text: "…"))
        }
        return lines
    }

    // MARK: Hook reply JSON (PreToolUse permissionDecision)

    /// Builds the `{stdout, exitCode}` server reply carrying the PreToolUse decision.
    static func reply(for decision: PermissionDecision) -> [String: Any] {
        let permission = (decision == .deny) ? "deny" : "allow"
        let reason = (decision == .deny) ? "Denied in Claude Notch" : "Approved in Claude Notch"
        let hookOutput: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": permission,
                "permissionDecisionReason": reason,
            ]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: hookOutput))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ["stdout": json, "exitCode": 0]
    }
}
