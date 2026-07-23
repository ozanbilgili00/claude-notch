import SwiftUI

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

    /// Approximate spring used for open/close, matched to Dynamic Island feel.
    static var expandSpring: Animation { .spring(response: 0.42, dampingFraction: 0.82) }
    static var quickSpring: Animation { .spring(response: 0.28, dampingFraction: 0.86) }
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
