import SwiftUI

/// A pixel creature whose motion tells you what a session is doing, so the notch reads at
/// a glance without parsing text:
///
/// | state     | motion                                    |
/// |-----------|-------------------------------------------|
/// | working   | walks — a bob-and-rock step cycle          |
/// | thinking  | slow breath (gentle scale)                 |
/// | waiting   | pulses, because it wants you               |
/// | error     | one short shudder, then still              |
/// | idle      | perfectly still, and nothing is scheduled  |
///
/// Idle really is idle: no timer, no animation, no redraws.
///
/// The artwork comes straight from Ozan's reference images in `Assets.xcassets`
/// (`turtle`, `claude-critter`) rather than hand-transcribed bitmaps — the references
/// aren't on a uniform pixel grid, so any re-gridding lost their character.
/// `.interpolation(.none)` keeps the pixels hard-edged at every size.
struct PixelCreature: View {
    let art: Art
    /// Tint applied only when the session needs attention; nil keeps the original art.
    var tint: Color?
    var height: CGFloat = 20
    var motion: Motion = .still

    enum Art: String {
        case turtle = "turtle"
        case claude = "claude-critter"
    }

    enum Motion: Equatable { case walking, breathing, pulsing, shuddering, still }

    @State private var step: CGFloat = 0      // walk bob
    @State private var breath: CGFloat = 1    // breathing scale
    @State private var glow: Double = 1       // pulse opacity
    @State private var shake: CGFloat = 0     // error shudder

    var body: some View {
        image
            .frame(height: height)
            .scaleEffect(breath, anchor: .bottom)
            .rotationEffect(.degrees(step * 4), anchor: .bottom)
            .offset(x: shake, y: -abs(step) * 1.5)
            .opacity(glow)
            .onAppear { apply(motion) }
            .onChange(of: motion) { _, new in apply(new) }
            .onDisappear { stop() }
    }

    @ViewBuilder
    private var image: some View {
        if let tint {
            Image(art.rawValue)
                .renderingMode(.template)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        } else {
            Image(art.rawValue)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    // MARK: Motion

    private func apply(_ motion: Motion) {
        stop()
        switch motion {
        case .walking:
            // Rock and bob: a two-pose gait, which is as close to a walk cycle as one
            // sprite gets without a second frame of artwork.
            withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) {
                step = 1
            }
        case .breathing:
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breath = 1.1
            }
        case .pulsing:
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                glow = 0.35
            }
        case .shuddering:
            // Deliberately not repeating — an error should register, not nag.
            withAnimation(.linear(duration: 0.05).repeatCount(6, autoreverses: true)) {
                shake = 1.5
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeOut(duration: 0.1)) { shake = 0 }
            }
        case .still:
            break
        }
    }

    /// Drop every running animation back to the resting pose.
    private func stop() {
        withAnimation(.linear(duration: 0)) {
            step = 0
            breath = 1
            glow = 1
            shake = 0
        }
    }
}

extension PixelCreature.Motion {
    /// How a session's status should move.
    static func forStatus(_ status: SessionStatus, activity: ActivityKind) -> Self {
        switch status {
        case .working:  return activity == .planning ? .breathing : .walking
        case .waiting:  return .pulsing
        case .error:    return .shuddering
        case .idle:     return .still
        }
    }
}
