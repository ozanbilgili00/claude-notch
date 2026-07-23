import SwiftUI

/// High-level state of a Claude Code session, shown as the notch's colored status dot.
enum SessionStatus: String, Codable, CaseIterable {
    case working   // 🟢 actively doing something
    case waiting   // 🟡 needs the user: permission or question pending
    case error     // 🔴 something failed
    case idle      // ⚪ session open but nothing in flight

    /// Priority used to decide which session drives the *closed* notch when several are active.
    /// Higher wins. Waiting (needs you) beats a working session; errors beat everything.
    var priority: Int {
        switch self {
        case .error:   return 3
        case .waiting: return 2
        case .working: return 1
        case .idle:    return 0
        }
    }

    var color: Color {
        switch self {
        case .working: return Theme.green
        case .waiting: return Theme.amber
        case .error:   return Theme.red
        case .idle:    return Theme.dim
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .error:   return "Error"
        case .idle:    return "Idle"
        }
    }
}
