import SwiftUI

/// One ring in the edge dock: a glyph inside a progress arc, with the percentage beneath.
///
/// The arc is drawn exactly the way `CircularGauge` draws it — same trim, same round cap,
/// same −90° rotation so it starts at twelve o'clock — because the two have to look like
/// the same instrument at different sizes. What differs is the middle: the dashboard gauge
/// puts the number in the centre, and at 34pt there is no room for it, so the glyph goes
/// inside and the number sits underneath.
struct EdgeRing: View {
    let kind: UsageRingKind
    let progress: Double
    let tint: Color
    var selected: Bool = false

    private static let diameter: CGFloat = 34
    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                ProgressArc(progress: clamped, tint: tint, lineWidth: 3)
                Image(systemName: kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.textDim)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            // The selected ring is lifted by a halo rather than by moving or resizing it:
            // the bubble's tail points here, and a ring that shifts would drag the tail
            // off its own anchor.
            .background {
                if selected {
                    Circle().fill(Theme.surfaceHi).padding(-5)
                }
            }

            Text(L10n.percent(Int(clamped * 100), Localization.shared.language))
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(selected ? Theme.text : Theme.textDim)
                .contentTransition(.numericText(value: clamped))
                .animation(Theme.Motion.value, value: Int(clamped * 100))
                .lineLimit(1).fixedSize()
        }
        .frame(width: EdgeGeometry.dockWidth, height: EdgeGeometry.ringSlot)
        .contentShape(Rectangle())
        .animation(Theme.Motion.quick, value: selected)
    }
}
