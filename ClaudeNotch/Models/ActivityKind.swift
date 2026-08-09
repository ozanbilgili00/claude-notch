import SwiftUI

/// What Claude is currently doing, derived from the most recent tool use.
enum ActivityKind: String, Codable {
    case editing      // Edit / Write / applying patches
    case running      // running tests / build
    case shell        // Bash / shell commands
    case planning     // plan mode / thinking
    case searching    // Grep / Glob / Read exploration
    case reading      // reading files
    case waiting      // waiting on approval / question
    case idle

    /// Maps a Claude Code tool name to an activity.
    static func from(toolName: String, command: String? = nil) -> ActivityKind {
        switch toolName {
        case "Edit", "Write", "NotebookEdit", "MultiEdit":
            return .editing
        case "Bash":
            if let c = command?.lowercased() {
                if c.contains("test") || c.contains("jest") || c.contains("pytest")
                    || c.contains("xcodebuild") || c.contains("swift test") {
                    return .running
                }
            }
            return .shell
        case "Grep", "Glob":
            return .searching
        case "Read":
            return .reading
        case "Task", "ExitPlanMode", "EnterPlanMode":
            return .planning
        case "AskUserQuestion":
            return .waiting
        default:
            return .shell
        }
    }

    var sfSymbol: String {
        switch self {
        case .editing:   return "pencil.and.outline"
        case .running:   return "testtube.2"
        case .shell:     return "terminal"
        case .planning:  return "brain"
        case .searching: return "magnifyingglass"
        case .reading:   return "doc.text"
        case .waiting:   return "hourglass"
        case .idle:      return "moon.zzz"
        }
    }

    @MainActor var verb: String {
        switch self {
        case .editing:   return L(.activityEditing)
        case .running:   return L(.activityRunningTests)
        case .shell:     return L(.activityRunning)
        case .planning:  return L(.activityPlanning)
        case .searching: return L(.activitySearching)
        case .reading:   return L(.activityReading)
        case .waiting:   return L(.activityWaiting)
        case .idle:      return L(.activityIdle)
        }
    }
}
