import SwiftUI

/// A pending permission ask surfaced from a PermissionRequest / PreToolUse hook.
struct PermissionRequest: Identifiable, Equatable {
    let id: String                 // request id (correlates hook <-> answer)
    var toolName: String           // "Edit", "Bash", ...
    // The heading is stored as a key rather than as text, so it stays correct if the
    // language changes while the request is on screen. nil means "use the tool name".
    var titleKey: L10n.Key?
    var reason: String?            // Claude's stated reason, if any
    var risk: RiskLevel
    var command: String?           // for Bash: the command
    var filePath: String?          // for Edit/Write: the file
    var diff: [DiffLine]           // for Edit/Write: rendered diff
    var createdAt: Date = Date()

    enum RiskLevel: String, Equatable {
        case low, medium, high
        var color: Color {
            switch self {
            case .low: return Theme.green
            case .medium: return Theme.amber
            case .high: return Theme.red
            }
        }
        /// Separate from `rawValue`, which is model data — deriving the label from it
        /// would mean the displayed text and the stored value change together.
        @MainActor var displayName: String {
            switch self {
            case .low:    return L(.riskLow)
            case .medium: return L(.riskMedium)
            case .high:   return L(.riskHigh)
            }
        }
    }
}

/// One line of a rendered diff for the permission preview.
struct DiffLine: Identifiable, Equatable {
    let id = UUID()
    enum Kind { case added, removed, context }
    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String

    var color: Color {
        switch kind {
        case .added:   return Theme.green
        case .removed: return Theme.red
        case .context: return Theme.textDim
        }
    }
    var sign: String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }
    var background: Color {
        switch kind {
        case .added:   return Theme.green.opacity(0.12)
        case .removed: return Theme.red.opacity(0.12)
        case .context: return .clear
        }
    }
}

/// The user's answer to a permission request.
enum PermissionDecision: String {
    case allowOnce
    case alwaysAllow
    case deny
}
