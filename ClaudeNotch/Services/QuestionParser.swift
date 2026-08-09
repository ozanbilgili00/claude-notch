import Foundation

/// Parses an AskUserQuestion tool_input into the notch `Question` model. Handles the
/// first question (the common case); additional questions in the same call are ignored
/// for now and fall through to Claude Code's own UI.
enum QuestionParser {
    static func parse(input: [String: Any], id: String) -> Question? {
        guard let questions = input["questions"] as? [[String: Any]],
              let q0 = questions.first else { return nil }

        let prompt = q0["question"] as? String ?? ""
        let header = q0["header"] as? String
        let options = (q0["options"] as? [[String: Any]]) ?? []
        let choices = options.enumerated().map { idx, o in
            Question.Choice(index: idx + 1,
                            label: o["label"] as? String ?? L10n.string(.optionFallback, Localization.stored)
                                .replacingOccurrences(of: "%d", with: "\(idx + 1)"),
                            detail: o["description"] as? String)
        }
        guard !choices.isEmpty else { return nil }
        return Question(id: id, header: header, prompt: prompt, choices: choices)
    }

    /// The hook reply that communicates the chosen answer back to Claude Code. We deny
    /// the interactive tool at PreToolUse and feed the selection back as the reason, so
    /// Claude proceeds with the user's answer without the terminal ever prompting.
    static func reply(answer: String) -> [String: Any] {
        let reason = "The user answered via Claude Notch: \"\(answer)\". "
            + "Treat this as their answer and continue; do not ask again."
        let hookOutput: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: hookOutput))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ["stdout": json, "exitCode": 0]
    }
}
