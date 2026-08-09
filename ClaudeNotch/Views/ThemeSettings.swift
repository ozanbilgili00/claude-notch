import SwiftUI
import Observation

/// The user's accent choice, kept observable so a change in Settings repaints the notch
/// immediately (SwiftUI tracks the read through `Theme.accent`).
///
/// Only *branding* uses the accent — the "You:" label, the prompt caret, the selected
/// tab. Status colors stay fixed on purpose: green/amber/red mean working/waiting/error,
/// so they carry information and must not follow a theme.
@MainActor
@Observable
final class ThemeSettings {
    static let shared = ThemeSettings()

    enum Accent: String, CaseIterable, Identifiable {
        case green, blue, violet, amber, red
        var id: String { rawValue }

        var color: Color {
            switch self {
            case .green:  return Theme.green
            case .blue:   return Theme.blue
            case .violet: return Theme.violet
            case .amber:  return Theme.amber
            case .red:    return Theme.red
            }
        }

        /// Kept apart from `rawValue`: that value is the UserDefaults key below, so
        /// deriving the label from it would tie the persisted setting to the UI language.
        @MainActor var displayName: String {
            switch self {
            case .green:  return L(.accentGreen)
            case .blue:   return L(.accentBlue)
            case .violet: return L(.accentViolet)
            case .amber:  return L(.accentAmber)
            case .red:    return L(.accentRed)
            }
        }
    }

    var accent: Accent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accentColor") }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "accentColor") ?? ""
        accent = Accent(rawValue: raw) ?? .green
    }
}

extension Theme {
    /// The current accent. Reading this inside a view body subscribes that view to
    /// accent changes.
    @MainActor
    static var accent: Color { ThemeSettings.shared.accent.color }
}
