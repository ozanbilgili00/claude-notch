import SwiftUI

/// A pixel creature whose motion tells you what a session is doing, so the notch reads at
/// a glance without parsing text:
///
/// | state     | motion                                                        |
/// |-----------|---------------------------------------------------------------|
/// | working   | walks — a real two-frame gait with a dust trail; `pace` sets the speed |
/// | thinking  | slow breath (gentle scale)                                     |
/// | waiting   | two hops and a "!" on arrival, then pulses — it wants you      |
/// | error     | one short shudder, then still                                  |
/// | idle      | still; blinks or fidgets now and then; after 5 min it dozes off |
///
/// One-off `event`s layer on top: a finished turn makes it hop with a burst of sparks.
///
/// Idle really is idle: no walk cycle, no dust, one redraw every few seconds. Asleep it
/// redraws four times a second for the drifting "z"s. With Reduce Motion on, all of it
/// stops except the error shudder, which carries meaning.
///
/// The artwork comes straight from Ozan's reference images in `Assets.xcassets` rather
/// than hand-transcribed bitmaps — the references aren't on a uniform pixel grid, so any
/// re-gridding lost their character. The extra frames (step, blink) are derived from
/// those same PNGs by moving whole pixel blocks, never by redrawing. Everything added
/// since (sparks, "z", "!") is drawn as separate square pixels around the art, not in it.
/// `.interpolation(.none)` keeps the pixels hard-edged at every size.
struct PixelCreature: View {
    let art: Art
    /// Tint applied only when the session needs attention; nil keeps the original art.
    var tint: Color?
    var height: CGFloat = 20
    var motion: Motion = .still
    /// Walking speed multiplier: 1 is a stroll, higher is busier.
    var pace: Double = 1
    /// The latest app event; the creature reacts when its id changes.
    var event: NotchEvent? = nil
    /// What the session is doing, for the pose on top of the motion: searching glances
    /// around, thinking shows "…", compacting squeezes.
    var activity: ActivityKind = .idle

    enum Art {
        case turtle, claude, gemini

        /// Frames of the walk cycle, in order.
        var walkFrames: [String] {
            switch self {
            case .turtle: return ["turtle", "turtle-walk"]
            case .claude: return ["claude-critter", "claude-critter-walk"]
            case .gemini: return ["gemini-star", "gemini-star-walk"]
            }
        }
        var restFrame: String { walkFrames[0] }

        /// Both frames of either art share one native size, so one ratio covers whichever
        /// is showing at a given tick.
        var aspect: CGFloat {
            switch self {
            case .turtle: return 144.0 / 86.0
            case .claude: return 448.0 / 400.0
            case .gemini: return 1
            }
        }

        /// Eyes moved one art pixel in a direction, derived from the rest frame by moving
        /// the eye blocks. The turtle has no eye to move, so it turns round instead.
        func lookFrame(_ gaze: Gaze) -> String? {
            guard hasEyes else { return nil }
            let base = restFrame
            switch gaze {
            case .left:  return base + "-look-left"
            case .right: return base + "-look-right"
            case .up:    return base + "-look-up"
            }
        }

        /// Claude and the Gemini star have eyes big enough to blink and glance with.
        var hasEyes: Bool { self != .turtle }

        /// Eyes-closed frame, where the artwork has eyes to close. The turtle's eye is
        /// under a point wide at notch size — a blink there is invisible — so it fidgets
        /// instead (see `scheduleIdleLife`).
        var blinkFrame: String? {
            hasEyes ? restFrame + "-blink" : nil
        }
    }

    enum Motion: Equatable { case walking, breathing, pulsing, shuddering, still }
    enum Gaze: CaseIterable { case left, right, up }

    @State private var breath: CGFloat = 1    // breathing scale
    @State private var glow: Double = 1       // pulse opacity
    @State private var shake: CGFloat = 0     // error shudder
    @State private var blinking = false
    @State private var idleTask: Task<Void, Never>?

    // Hops: vertical lift plus squash-and-stretch, anchored at the feet.
    @State private var lift: CGFloat = 0
    @State private var squash = CGSize(width: 1, height: 1)
    @State private var hopTask: Task<Void, Never>?

    @State private var gaze: Gaze?
    /// Turtle looking back over its shell — its version of glancing around.
    @State private var turned = false
    @State private var gazeTask: Task<Void, Never>?

    @State private var sparks: SparkBurst?
    @State private var asleep = false
    @State private var alerting = false

    private var isWalking: Bool { motion == .walking && Theme.Motion.loopsAllowed }

    /// One full two-frame step at pace 1.
    private static let stepDuration: TimeInterval = 0.36
    private var step: TimeInterval { Self.stepDuration / min(max(pace, 0.5), 2.2) }

    /// Pixel size of the overlays: the art's own pixel pitch at this height, roughly.
    private var unit: CGFloat { max(1, (height / 12).rounded()) }

    var body: some View {
        Group {
            if isWalking {
                // A timeline rather than a repeating animation: frame swaps are discrete,
                // and this caps the redraw rate instead of leaving it to the animator.
                TimelineView(.animation(minimumInterval: step / 2)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    walkingBody(phase: t.truncatingRemainder(dividingBy: step) / step)
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
        .scaleEffect(x: squash.width * (turned ? -1 : 1), y: squash.height * breath, anchor: .bottom)
        .offset(x: shake, y: lift)
        .opacity(glow)
        // Overlays draw outside the fixed box on purpose and never feed back into layout.
        .overlay(alignment: .topTrailing) {
            if alerting { AlertMark(unit: unit).offset(x: unit * 3, y: -unit * 2 + lift) }
        }
        .overlay(alignment: .topTrailing) {
            if asleep { SleepZs(unit: unit).offset(x: unit * 4, y: -unit * 3) }
        }
        .overlay(alignment: .topTrailing) {
            if isThinking { ThoughtDots(unit: unit).offset(x: unit * 5, y: -unit * 3) }
        }
        .overlay {
            if let sparks { SparkView(burst: sparks, unit: unit) }
        }
        .onAppear { apply(motion, entering: false); scheduleIdleLife(); scheduleGazing() }
        .onChange(of: motion) { _, new in apply(new, entering: true); scheduleGazing() }
        .onChange(of: activity) { _, _ in apply(motion, entering: false); scheduleGazing() }
        .onChange(of: event?.id) { _, _ in react(to: event) }
        .onDisappear { stop(); idleTask?.cancel(); hopTask?.cancel(); gazeTask?.cancel() }
    }

    private var isThinking: Bool {
        motion == .breathing && activity == .planning && Theme.Motion.loopsAllowed
    }

    /// Blinking is what keeps a *stopped* creature from looking switched off. Asleep, the
    /// eyes stay shut; waiting, they look up at the "!".
    private var currentRestFrame: String {
        if (blinking || asleep), let blink = art.blinkFrame { return blink }
        if alerting, let up = art.lookFrame(.up) { return up }
        if let gaze, let look = art.lookFrame(gaze) { return look }
        return art.restFrame
    }

    /// The step frame plus a little dust kicking backwards — the dust is what actually
    /// sells the walk at 20pt, more than the leg swap does.
    private func walkingBody(phase: Double) -> some View {
        // The planted-foot frame can carry a glance; the stride frame keeps its own eyes.
        let planted = phase < 0.5
        let frame = planted ? (gaze.flatMap(art.lookFrame) ?? art.walkFrames[0]) : art.walkFrames[1]
        return sprite(named: frame)
            // A half-pixel lift on the stride: the bob is what makes it read as a step
            // rather than as two pictures alternating.
            .offset(y: planted ? 0 : -unit * 0.5)
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

    private func apply(_ motion: Motion, entering: Bool) {
        stop()
        asleep = false
        withAnimation(Theme.Motion.pop) { alerting = motion == .pulsing && Theme.Motion.loopsAllowed }
        scheduleIdleLife()
        guard Theme.Motion.loopsAllowed || motion == .shuddering else { return }
        switch motion {
        case .walking:
            break                       // driven by the timeline above
        case .breathing where activity == .compacting:
            // Compacting squeezes the conversation; the creature squeezes with it.
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                breath = 0.82
            }
        case .breathing:
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breath = 1.1
            }
        case .pulsing:
            // Arriving at "wants you" gets two quick hops first; the pulse is what stays.
            if entering { hop(times: 2, height: 3, sparkTint: nil) }
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

    private func react(to event: NotchEvent?) {
        guard let event, Theme.Motion.loopsAllowed else { return }
        let wasAsleep = asleep
        if asleep { withAnimation(Theme.Motion.quick) { asleep = false; breath = 1 } }
        switch event.kind {
        case .completed:  hop(times: 1, height: 6, sparkTint: Theme.green, delay: wasAsleep ? 0.25 : 0)
        case .usageReset: hop(times: 1, height: 4, sparkTint: Theme.blue)
        case .usageWarning: hop(times: 1, height: 3, sparkTint: Theme.amber)
        case .attention, .failed: break   // carried by the motion change itself
        }
        scheduleIdleLife()
    }

    /// Squash, spring up stretched, land squashed, settle. `height` is in art pixels.
    private func hop(times: Int, height: CGFloat, sparkTint: Color?, delay: Double = 0) {
        hopTask?.cancel()
        // Half an art pixel per step: the pill leaves only a few points above the head,
        // and a hop that clips against the menu bar reads as a glitch, not a jump.
        let rise = -height * unit * 0.5
        hopTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            for i in 0..<times {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.07)) { squash = CGSize(width: 1.12, height: 0.8) }
                try? await Task.sleep(for: .milliseconds(70))
                withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                    lift = rise
                    squash = CGSize(width: 0.92, height: 1.12)
                }
                if i == 0, let sparkTint { sparks = SparkBurst(tint: sparkTint) }
                try? await Task.sleep(for: .milliseconds(170))
                withAnimation(.easeIn(duration: 0.12)) { lift = 0; squash = CGSize(width: 1, height: 1) }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeOut(duration: 0.06)) { squash = CGSize(width: 1.1, height: 0.86) }
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(Theme.Motion.celebrate) { squash = CGSize(width: 1, height: 1) }
                try? await Task.sleep(for: .milliseconds(90))
            }
            try? await Task.sleep(for: .milliseconds(500))
            sparks = nil
        }
    }

    /// While still: a blink (Claude) or a one-pixel fidget (turtle) every few seconds,
    /// and after five quiet minutes, sleep.
    private func scheduleIdleLife() {
        idleTask?.cancel()
        guard motion == .still, Theme.Motion.loopsAllowed else { return }
        let stillSince = Date()
        idleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 4000...8000)))
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(stillSince) > 300 {
                    fallAsleep()
                    return
                }
                // A mix of small habits, so it never settles into a visible loop.
                let roll = Int.random(in: 0..<10)
                if art.hasEyes {
                    if roll < 6 {
                        blinking = true
                        try? await Task.sleep(for: .milliseconds(120))
                        blinking = false
                    } else {
                        gaze = Gaze.allCases.randomElement()
                        try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1100)))
                        gaze = nil
                    }
                } else if roll < 6 {
                    hop(times: 1, height: 1.5, sparkTint: nil)
                } else {
                    turned = true
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 700...1200)))
                    turned = false
                }
            }
        }
    }

    /// Searching and reading: the eyes dart about (Claude) or the turtle checks behind it
    /// now and then, in time with the walk rather than on every step.
    private func scheduleGazing() {
        gazeTask?.cancel()
        gaze = nil
        turned = false
        guard motion == .walking, activity == .searching || activity == .reading,
              Theme.Motion.loopsAllowed else { return }
        gazeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 900...1600)))
                guard !Task.isCancelled else { return }
                if art.hasEyes {
                    gaze = [Gaze.left, .right].randomElement()
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 400...700)))
                    gaze = nil
                } else if Int.random(in: 0..<3) == 0 {
                    turned = true
                    try? await Task.sleep(for: .milliseconds(450))
                    turned = false
                }
            }
        }
    }

    private func fallAsleep() {
        withAnimation(.easeInOut(duration: 0.6)) { asleep = true }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { breath = 1.04 }
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

// MARK: - Pixel overlays

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

private struct SparkBurst: Equatable {
    let id = UUID()
    var tint: Color
}

/// Four pixels flung out from the creature on a hop, fading as they fly.
private struct SparkView: View {
    let burst: SparkBurst
    let unit: CGFloat
    @State private var t: CGFloat = 0

    private static let directions: [CGVector] = [
        CGVector(dx: -1, dy: -0.9), CGVector(dx: 1, dy: -1), CGVector(dx: -0.5, dy: -1.4),
        CGVector(dx: 0.7, dy: -1.5),
    ]

    var body: some View {
        Canvas { ctx, size in
            let origin = CGPoint(x: size.width / 2, y: size.height * 0.45)
            ctx.opacity = Double(1 - t)
            for d in Self.directions {
                let p = CGPoint(x: origin.x + d.dx * unit * 9 * t, y: origin.y + d.dy * unit * 7 * t)
                ctx.fill(Path(CGRect(x: p.x, y: p.y, width: unit, height: unit)), with: .color(burst.tint))
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.55)) { t = 1 } }
        .id(burst.id)
    }
}

/// A pixel "!" bobbing beside the head while the creature waits for you.
private struct AlertMark: View {
    let unit: CGFloat
    @State private var up = false

    var body: some View {
        Canvas { ctx, _ in
            for y in 0..<3 {
                ctx.fill(Path(CGRect(x: 0, y: CGFloat(y) * unit, width: unit, height: unit)),
                         with: .color(Theme.amber))
            }
            ctx.fill(Path(CGRect(x: 0, y: 4 * unit, width: unit, height: unit)), with: .color(Theme.amber))
        }
        .frame(width: unit, height: unit * 5)
        .offset(y: up ? -unit : 0)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { up = true }
        }
    }
}

/// Three pixels lighting up one after another above the head: thinking.
private struct ThoughtDots: View {
    let unit: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let lit = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 4
            Canvas { ctx, _ in
                for i in 0..<3 where i < lit {
                    ctx.fill(Path(CGRect(x: CGFloat(i) * unit * 2, y: CGFloat(2 - i) * unit * 0.6,
                                         width: unit, height: unit)),
                             with: .color(Theme.textDim))
                }
            }
        }
        .frame(width: unit * 6, height: unit * 3)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Two pixel "z"s drifting up and fading, staggered, while the creature sleeps.
private struct SleepZs: View {
    let unit: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<2 {
                    let local = CGFloat((t / 2.4 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1))
                    let scale: CGFloat = i == 0 ? 1 : 0.75
                    let px = unit * scale
                    let x = local * unit * 3
                    let y = size.height - px * 3 - local * unit * 6
                    ctx.opacity = Double(sin(local * .pi))
                    // A 3×3 "z": top row, middle pixel, bottom row.
                    for c in 0..<3 {
                        ctx.fill(Path(CGRect(x: x + CGFloat(c) * px, y: y, width: px, height: px)),
                                 with: .color(Theme.textDim))
                        ctx.fill(Path(CGRect(x: x + CGFloat(c) * px, y: y + 2 * px, width: px, height: px)),
                                 with: .color(Theme.textDim))
                    }
                    ctx.fill(Path(CGRect(x: x + px, y: y + px, width: px, height: px)),
                             with: .color(Theme.textDim))
                }
            }
        }
        .frame(width: unit * 7, height: unit * 10)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

extension PixelCreature.Motion {
    /// How a session's status should move.
    static func forStatus(_ status: SessionStatus, activity: ActivityKind) -> Self {
        switch status {
        case .working:  return activity == .planning || activity == .compacting ? .breathing : .walking
        case .waiting:  return .pulsing
        case .error:    return .shuddering
        case .idle:     return .still
        }
    }
}

extension PixelCreature {
    /// Walking speed for what the sessions are doing: shell work and tests hurry, reading
    /// ambles, and each extra busy session adds a little.
    static func pace(for activity: ActivityKind, working: Int) -> Double {
        let base: Double
        switch activity {
        case .running, .shell:     base = 1.35
        case .editing:             base = 1.1
        case .searching, .reading: base = 0.85
        default:                   base = 1
        }
        return min(base + 0.15 * Double(max(0, working - 1)), 2)
    }
}
