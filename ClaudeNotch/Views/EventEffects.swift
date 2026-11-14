import SwiftUI

extension NotchEvent.Kind {
    /// The colour an event flashes in — the same colours the app already uses for these
    /// states everywhere else.
    var tint: Color {
        switch self {
        case .completed:    return Theme.green
        case .failed:       return Theme.red
        case .attention:    return Theme.amber
        case .usageWarning: return Theme.amber
        case .usageReset:   return Theme.blue
        }
    }
}

/// A band of light that runs once across the shape it is laid over when something
/// happens: along the pill for the notch, down the strip for the edge dock. It is the
/// closed notch's way of saying "that just finished" without growing or making a sound.
struct EventSweep: View {
    let event: NotchEvent?
    var vertical = false

    @State private var phase: CGFloat = 0
    @State private var tint: Color = .clear
    @State private var visible = false

    var body: some View {
        GeometryReader { g in
            let length = vertical ? g.size.height : g.size.width
            let band = length * 0.55
            LinearGradient(colors: [.clear, tint.opacity(0.18), tint.opacity(0.42),
                                    tint.opacity(0.18), .clear],
                           startPoint: vertical ? .top : .leading,
                           endPoint: vertical ? .bottom : .trailing)
                .frame(width: vertical ? g.size.width : band,
                       height: vertical ? band : g.size.height)
                .offset(x: vertical ? 0 : -band + phase * (length + band),
                        y: vertical ? -band + phase * (length + band) : 0)
        }
        .opacity(visible ? 1 : 0)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .onChange(of: event?.id) { _, _ in run() }
    }

    private func run() {
        guard let event, Theme.Motion.loopsAllowed, UserDefaults.standard.eventAnimationsEnabled
        else { return }
        tint = event.kind.tint
        phase = 0
        visible = true
        withAnimation(.easeInOut(duration: 0.85)) { phase = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            visible = false
        }
    }
}

/// The shape reacting physically: a quick outward bump when something wants the user
/// (at most every 20 s, so a string of permissions doesn't make it throb), and a short
/// shake on a failure.
struct EventNudge: ViewModifier {
    let event: NotchEvent?
    /// The side the shape grows from: top for the notch, trailing for the edge dock.
    var anchor: UnitPoint = .top
    var vertical = false

    @State private var bump: CGFloat = 0
    @State private var shake: CGFloat = 0
    @State private var lastBump = Date.distantPast

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: vertical ? 1 + bump * 0.5 : 1 + bump,
                         y: vertical ? 1 + bump : 1 + bump * 0.5, anchor: anchor)
            .offset(x: vertical ? 0 : shake, y: vertical ? shake : 0)
            .onChange(of: event?.id) { _, _ in react() }
    }

    private func react() {
        guard let event, Theme.Motion.loopsAllowed, UserDefaults.standard.eventAnimationsEnabled
        else { return }
        switch event.kind {
        case .attention, .usageWarning:
            guard Date().timeIntervalSince(lastBump) > 20 else { return }
            lastBump = Date()
            withAnimation(Theme.Motion.nudge) { bump = 0.045 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(Theme.Motion.celebrate) { bump = 0 }
            }
        case .failed:
            withAnimation(.linear(duration: 0.05).repeatCount(5, autoreverses: true)) { shake = 3 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.easeOut(duration: 0.1)) { shake = 0 }
            }
        case .completed, .usageReset:
            break
        }
    }
}

extension View {
    func eventNudge(_ event: NotchEvent?, anchor: UnitPoint = .top, vertical: Bool = false) -> some View {
        modifier(EventNudge(event: event, anchor: anchor, vertical: vertical))
    }
}
