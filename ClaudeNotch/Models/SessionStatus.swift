import SwiftUI

/// High-level state of a Claude Code session, shown as the notch's colored status dot.
enum SessionStatus: String, Codable, CaseIterable {
    case working   // 🟢 actively doing something
    case waiting   // 🟡 needs the user: permission or question pending
    case error     // 🔴 something failed
    case idle      // ⚪ session open but nothing in flight

    /// Tint for the creature artwork, or nil to draw it in its own colors. It keeps
    /// Claude's orange until the session actually needs the user — so using the brand
    /// artwork doesn't cost us the "something wants you" signal.
    var creatureTint: Color? {
        switch self {
        case .waiting: return Theme.amber
        case .error:   return Theme.red
        case .working: return nil
        case .idle:    return nil
        }
    }

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
}
