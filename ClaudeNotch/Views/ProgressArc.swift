import SwiftUI

/// The progress ring shared by the dashboard gauge and the edge dock, so both behave
/// identically: it fills from empty the first time it appears, slides to new values,
/// blends its colour as it crosses into a new band, and flares once when usage climbs
/// past a band edge — the moment worth noticing, not every tick of the number.
struct ProgressArc: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat

    /// Band edges where the tint changes; crossing one upwards earns the flare.
    static let bands: [Double] = [0.6, 0.85]

    @State private var shown: Double = 0
    @State private var flare = false

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(flare ? 0.9 : 0), radius: flare ? lineWidth * 2 : 0)
                .scaleEffect(flare ? 1.06 : 1)
        }
        .animation(Theme.Motion.value, value: tint)
        .onAppear {
            withAnimation(Theme.Motion.fill.delay(Theme.Motion.reduced ? 0 : 0.08)) { shown = clamped }
        }
        .onChange(of: clamped) { old, new in
            withAnimation(Theme.Motion.value) { shown = new }
            if Self.band(new) > Self.band(old) { flareOnce() }
        }
    }

    static func band(_ value: Double) -> Int { bands.filter { value >= $0 }.count }

    private func flareOnce() {
        guard Theme.Motion.loopsAllowed else { return }
        withAnimation(.easeOut(duration: 0.22)) { flare = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeInOut(duration: 0.7)) { flare = false }
        }
    }
}
