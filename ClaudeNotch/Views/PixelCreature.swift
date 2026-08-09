import SwiftUI

/// A pixel creature whose motion tells you what a session is doing, so the notch reads at
/// a glance without parsing text:
///
/// | state     | motion                                          |
/// |-----------|-------------------------------------------------|
/// | working   | walks — a real two-frame gait, with a dust trail |
/// | thinking  | slow breath (gentle scale)                       |
/// | waiting   | pulses, because it wants you                     |
/// | error     | one short shudder, then still                    |
/// | idle      | still, but blinks now and then                   |
///
/// Idle really is idle: no walk cycle, no dust, one redraw every few seconds for a blink.
/// With Reduce Motion on, even that stops.
///
/// The artwork comes straight from Ozan's reference images in `Assets.xcassets` rather
/// than hand-transcribed bitmaps — the references aren't on a uniform pixel grid, so any
/// re-gridding lost their character. The extra frames (step, blink) are derived from
/// those same PNGs by moving whole pixel blocks, never by redrawing.
/// `.interpolation(.none)` keeps the pixels hard-edged at every size.
struct PixelCreature: View {
    let art: Art
    /// Tint applied only when the session needs attention; nil keeps the original art.
    var tint: Color?
    var height: CGFloat = 20
    var motion: Motion = .still

    enum Art {
        case turtle, claude

        /// Frames of the walk cycle, in order.
        var walkFrames: [String] {
            switch self {
            case .turtle: return ["turtle", "turtle-walk"]
            case .claude: return ["claude-critter", "claude-critter-walk"]
            }
        }
        var restFrame: String { walkFrames[0] }
        /// Both frames of either art share one native size, so one ratio covers whichever
        /// is showing at a given tick.
        var aspect: CGFloat {
            switch self {
            case .turtle: return 144.0 / 86.0
            case .claude: return 448.0 / 400.0
            }
        }
        /// Eyes-closed frame, where the artwork has eyes to close.
        var blinkFrame: String? {
            switch self {
            case .claude: return "claude-critter-blink"
            case .turtle: return nil
            }
        }
    }

    enum Motion: Equatable { case walking, breathing, pulsing, shuddering, still }

    @State private var breath: CGFloat = 1    // breathing scale
    @State private var glow: Double = 1       // pulse opacity
    @State private var shake: CGFloat = 0     // error shudder
    @State private var blinking = false
    @State private var blinkTask: Task<Void, Never>?

    private var isWalking: Bool { motion == .walking && Theme.Motion.loopsAllowed }
    /// One full two-frame step.
    private static let stepDuration: TimeInterval = 0.36

    var body: some View {
        Group {
            if isWalking {
                // A timeline rather than a repeating animation: frame swaps are discrete,
                // and this caps the redraw rate instead of leaving it to the animator.
                TimelineView(.animation(minimumInterval: Self.stepDuration / 2)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    walkingBody(phase: t.truncatingRemainder(dividingBy: Self.stepDuration)
                                        / Self.stepDuration)
                }
            } else {
                sprite(named: currentRestFrame)
            }
        }
        // Both width AND height fixed, not just height: while walking, the content is a
        // TimelineView that swaps children every tick. Left to size itself from the image
        // inside, matchedGeometryEffect — tracking this view across the pill/panel morph —
        // renegotiates geometry on every one of those swaps and can get stuck reporting a
        // degenerate frame, rendering the creature invisible for as long as it keeps
        // walking. A fixed box holds still regardless of what churns inside it.
        .frame(width: height * art.aspect, height: height)
        .scaleEffect(breath, anchor: .bottom)
        .offset(x: shake)
        .opacity(glow)
        .onAppear { apply(motion); scheduleBlink() }
        .onChange(of: motion) { _, new in apply(new) }
        .onDisappear { stop(); blinkTask?.cancel() }
    }

    /// Blinking is what keeps a *stopped* creature from looking switched off.
    private var currentRestFrame: String {
        if blinking, let blink = art.blinkFrame { return blink }
        return art.restFrame
    }

    /// The step frame plus a little dust kicking backwards — the dust is what actually
    /// sells the walk at 20pt, more than the leg swap does.
    private func walkingBody(phase: Double) -> some View {
        let frame = art.walkFrames[phase < 0.5 ? 0 : 1]
        return sprite(named: frame)
            .background(alignment: .bottomLeading) {
                DustTrail(phase: phase, tint: tint ?? Theme.dim, height: height)
            }
    }

    @ViewBuilder
    private func sprite(named name: String) -> some View {
        if let tint {
            Image(name)
                .renderingMode(.template)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        } else {
            Image(name)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    // MARK: Motion

    private func apply(_ motion: Motion) {
        stop()
        guard Theme.Motion.loopsAllowed || motion == .shuddering else { return }
        switch motion {
        case .walking:
            break                       // driven by the timeline above
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

    /// A blink every few seconds, at random, so several creatures on screen don't blink
    /// in lockstep. One redraw per blink — cheap enough to leave running while idle.
    private func scheduleBlink() {
        guard art.blinkFrame != nil, Theme.Motion.loopsAllowed else { return }
        blinkTask?.cancel()
        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 3000...7000)))
                guard !Task.isCancelled else { return }
                blinking = true
                try? await Task.sleep(for: .milliseconds(120))
                blinking = false
            }
        }
    }

    /// Drop every running animation back to the resting pose.
    private func stop() {
        withAnimation(.linear(duration: 0)) {
            breath = 1
            glow = 1
            shake = 0
        }
    }
}

/// Three specks drifting backwards under a walking creature. Drawn in a Canvas so the
/// moving specks never trigger a layout pass in the row that contains them.
private struct DustTrail: View {
    let phase: Double
    let tint: Color
    let height: CGFloat

    var body: some View {
        let unit = max(1, height / 12)
        Canvas { ctx, size in
            for i in 0..<3 {
                let local = (phase + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let x = size.width - unit * (1 + 2 * local) - CGFloat(i) * unit * 1.8
                let rect = CGRect(x: x, y: size.height - unit * 1.5, width: unit, height: unit)
                ctx.opacity = 0.35 * (1 - local)
                ctx.fill(Path(rect), with: .color(tint))
            }
        }
        .frame(width: unit * 7, height: height)
        .allowsHitTesting(false)
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
