import Foundation
import Observation

/// The app's display language, switchable from Settings without a relaunch.
///
/// Deliberately not a String Catalog: a catalog picks its `.lproj` from `AppleLanguages`
/// at *launch*, so an in-app switch would need a restart. Modelled on `ThemeSettings`
/// instead — an observable singleton whose value is read inside view bodies, so changing
/// it repaints the notch the same way changing the accent colour does.
@MainActor
@Observable
final class Localization {
    static let shared = Localization()

    enum Language: String, CaseIterable, Identifiable {
        case tr, en
        var id: String { rawValue }

        /// Languages are always named in their own language — a Turkish speaker looking
        /// for Turkish shouldn't have to recognise the word "Turkish" first.
        var endonym: String {
            switch self {
            case .tr: return "Türkçe"
            case .en: return "English"
            }
        }
    }

    var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    // nonisolated so `stored` below can read it without hopping to the main actor.
    nonisolated private static let key = "language"

    private init() {
        language = Self.stored
    }

    /// The persisted choice, readable without hopping to the main actor — the CLI paths
    /// in `Entry.swift` and the usage parser run outside it.
    nonisolated static var stored: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .tr
    }
}

/// Look up a string in the current language.
///
/// Reading `Localization.shared.language` here is what makes translation reactive: a view
/// that calls `L(...)` in its body is subscribed to the language, so switching it in
/// Settings repaints that view immediately.
@MainActor
func L(_ key: L10n.Key) -> String {
    L10n.string(key, Localization.shared.language)
}

@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    String(format: L10n.string(key, Localization.shared.language), arguments: args)
}

/// English pluralises after a numeral and Turkish does not ("3 sessions" / "3 oturum"),
/// so count-dependent strings carry both forms rather than going through a plural engine —
/// there are only three such strings in the app.
@MainActor
func Lcount(_ one: L10n.Key, _ many: L10n.Key, _ n: Int) -> String {
    n == 1 ? L(one) : L(many, n)
}
