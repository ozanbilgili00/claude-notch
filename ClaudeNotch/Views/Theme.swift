import SwiftUI
import AppKit

/// Retro-terminal design system for Claude Notch.
/// Dark, high-contrast, monospaced — with colored badges for models/tools,
/// tuned to feel like the reference screenshots while keeping Apple-grade motion.
enum Theme {

    // MARK: Palette
    static let ink        = Color.black                      // notch body
    static let surface    = Color(white: 0.09)              // panels / rows
    static let surfaceHi   = Color(white: 0.14)             // hovered rows
    static let stroke     = Color(white: 1.0, opacity: 0.08)
    static let text       = Color(white: 0.96)
    static let textDim    = Color(white: 0.62)
    static let dim        = Color(white: 0.45)

    static let green  = Color(red: 0.30, green: 0.85, blue: 0.46)
    static let amber  = Color(red: 0.98, green: 0.74, blue: 0.25)
    static let red    = Color(red: 0.96, green: 0.34, blue: 0.34)
    static let blue   = Color(red: 0.38, green: 0.60, blue: 0.98)
    static let violet = Color(red: 0.66, green: 0.55, blue: 0.98)

    // MARK: Typography — monospaced everywhere for the terminal feel
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let title    = mono(13, .semibold)
    static let body     = mono(12, .regular)
    static let caption  = mono(11, .regular)
    static let micro    = mono(9.5, .medium)

    // MARK: Metrics
    static let notchCorner: CGFloat = 12      // physical notch bottom corners
    static let panelCorner: CGFloat = 22      // expanded panel corners
    static let rowCorner: CGFloat = 10

    // MARK: Motion

    /// Every animation in the app, in one place, so "Reduce Motion" is a single switch
    /// rather than a hunt through view files.
    enum Motion {
        /// macOS's own accessibility preference. Read live: it is cheap, and the value
        /// only needs to be right at the moment an animation starts.
        /// `NOTCH_REDUCE_MOTION=1` forces it on, so the reduced path can be exercised
        /// without changing a system setting.
        static var reduced: Bool {
            if ProcessInfo.processInfo.environment["NOTCH_REDUCE_MOTION"] == "1" { return true }
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// Opening gets a little overshoot, closing gets none — the asymmetry is what
        /// makes a panel feel like it springs out and settles back rather than bouncing
        /// in both directions.
        static var open: Animation {
            reduced ? .easeOut(duration: 0.18)
                    : .spring(response: 0.48, dampingFraction: 0.76)
        }
        static var close: Animation {
            reduced ? .easeOut(duration: 0.14)
                    : .spring(response: 0.34, dampingFraction: 0.92)
        }
        static var quick: Animation {
            reduced ? .easeOut(duration: 0.12)
                    : .spring(response: 0.28, dampingFraction: 0.86)
        }
        /// For value read-outs: snappy, no bounce, so numbers stay legible mid-flight.
        static var value: Animation {
            reduced ? .linear(duration: 0.01) : .snappy(duration: 0.28)
        }

        /// Delay between successive rows in a staggered reveal.
        static let stagger: Double = 0.03
        /// How long the closed pill lingers before the panel takes over. Fading the
        /// outgoing content faster than the incoming reads as growth, not dissolve.
        static let crossfade: Double = 0.10

        /// Continuous loops (breathing, shimmer, walking) are suppressed entirely when
        /// the user has asked for less motion.
        static var loopsAllowed: Bool { !reduced }
    }
}

/// A small colored capsule badge — used for model names, tools, terminals.
struct Badge: View {
    let text: String
    var tint: Color = Theme.textDim
    var body: some View {
        Text(text)
            .font(Theme.micro)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            )
            .fixedSize()
    }
}

extension Color {
    /// Deterministic tint for a model/tool name so badges are colorful yet stable.
    static func forToken(_ name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("claude") || lower.contains("opus")
            || lower.contains("sonnet") || lower.contains("haiku") || lower.contains("fable") {
            return Theme.violet
        }
        if lower.contains("grok") { return Theme.green }
        if lower.contains("gpt") || lower.contains("codex") { return Theme.blue }
        // Fallback: hash to a hue.
        let h = Double(abs(name.hashValue) % 360) / 360.0
        return Color(hue: h, saturation: 0.55, brightness: 0.9)
    }
}
