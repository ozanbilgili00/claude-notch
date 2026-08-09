import SwiftUI

/// Root of the notch content. Draws the black notch shape and morphs between the closed
/// pill and the expanded panel: one body that grows, with the shared status elements
/// flying between layouts rather than two views swapping places.
struct NotchRootView: View {
    @Bindable var store: SessionStore
    @Bindable var model: NotchViewModel

    @Namespace private var ns

    private var isClosed: Bool { model.presentation == .closed }

    var body: some View {
        VStack(spacing: 0) {
            morphBody
                // The bloom is deliberately wider than the notch, so it goes in a
                // background rather than a sibling: background content can overflow
                // without feeding its size back into the window, which otherwise sends
                // the hosting view into an endless layout loop.
                .background(alignment: .bottom) {
                    StatusBloom(status: store.aggregateStatus,
                                width: model.currentSize.width * 0.78)
                        .offset(y: 18 + StatusBloom.bleed)
                }
                .onHover { model.hoverIntent($0) }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all, edges: .all)
        // React to blocking events by forcing the panel open.
        .onChange(of: store.blockingSession?.id) { _, newValue in
            if let id = newValue {
                store.selectedID = id       // focus the session that needs the user
                model.forceOpen()
            } else {
                model.unlockAndMaybeCollapse()
            }
        }
        .onAppear {
            if store.blockingSession != nil { model.forceOpen() }
            if ProcessInfo.processInfo.environment["NOTCH_START_EXPANDED"] == "1" {
                model.expand()
            }
        }
    }

    // MARK: Body

    /// The black shape itself: sized by the current presentation, filled, clipped and
    /// shadowed as one unit so the whole thing reads as a single object changing size.
    ///
    /// The shadowed body is a *background* layer, deliberately separate from the content.
    /// Shadowing the composite instead would make every animating pixel inside (walking
    /// creatures, equalizer bars) re-run two full-panel blur passes — the difference
    /// between ~1% and ~25% CPU.
    private var morphBody: some View {
        contentStack
            .frame(width: model.currentSize.width,
                   height: model.currentSize.height, alignment: .top)
            .clipShape(bodyShape)
            .background {
                bodyShape
                    .fill(Color.black)
                    .overlay { bodyDecoration }
                    // No drop shadow: against a dark desktop the wide soft one reads as a
                    // grey smudge under the panel rather than depth. The specular top
                    // edge and the body gradient carry the depth instead.
            }
            .geometryGroup()
    }

    private var bodyShape: NotchBackgroundShape {
        NotchBackgroundShape(bottomCorner: isClosed ? Theme.notchCorner : Theme.panelCorner,
                             topCorner: isClosed ? 0 : Theme.panelCorner)
    }

    /// Pure black while closed so the pill fuses with the physical notch; once it is a
    /// floating panel it can afford a whisper of gradient, a specular top edge and grain.
    @ViewBuilder
    private var bodyDecoration: some View {
        if !isClosed {
            ZStack {
                LinearGradient(colors: [Color(white: 0.055), Color(white: 0.012)],
                               startPoint: .top, endPoint: .bottom)
                GrainOverlay()
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
            .clipShape(bodyShape)
            .overlay { bodyShape.strokeBorder(Theme.stroke, lineWidth: 1) }
        }
    }

    /// Both states share one stack so the crossfade can overlap. The closed pill stays
    /// mounted (it is tiny); the panel is only built while it is on screen, so a closed
    /// notch runs no scroll views, timers or animations.
    private var contentStack: some View {
        ZStack(alignment: .top) {
            ClosedStateView(store: store,
                            isRealNotch: model.notch.isReal,
                            notchWidth: model.notch.notchSize.width,
                            ns: ns,
                            isSource: isClosed)
                .frame(width: model.closedSize.width, height: model.closedSize.height)
                .opacity(isClosed ? 1 : 0)
                .blur(radius: isClosed ? 0 : 5)
                .allowsHitTesting(isClosed)

            if !isClosed {
                ExpandedView(store: store, model: model, ns: ns)
                    .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                    .transition(.opacity.animation(
                        .easeOut(duration: 0.22)
                            .delay(Theme.Motion.reduced ? 0 : Theme.Motion.crossfade)))
            }
        }
    }
}

/// Rounded-bottom (and optionally rounded-top) shape for the notch/panel body.
/// The corner radii are animatable so opening doesn't snap 12pt → 22pt in one frame.
struct NotchBackgroundShape: InsettableShape {
    var bottomCorner: CGFloat
    var topCorner: CGFloat
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomCorner, topCorner) }
        set { bottomCorner = newValue.first; topCorner = newValue.second }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var c = self; c.inset += amount; return c
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let maxCorner = min(r.width, r.height) / 2
        let tc = max(0, min(topCorner, maxCorner))
        let bc = max(0, min(bottomCorner, maxCorner))

        var p = Path()
        p.move(to: CGPoint(x: r.minX + tc, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tc, y: r.minY))
        if tc > 0 {
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + tc),
                           control: CGPoint(x: r.maxX, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bc))
        if bc > 0 {
            p.addQuadCurve(to: CGPoint(x: r.maxX - bc, y: r.maxY),
                           control: CGPoint(x: r.maxX, y: r.maxY))
        }
        p.addLine(to: CGPoint(x: r.minX + bc, y: r.maxY))
        if bc > 0 {
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - bc),
                           control: CGPoint(x: r.minX, y: r.maxY))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tc))
        if tc > 0 {
            p.addQuadCurve(to: CGPoint(x: r.minX + tc, y: r.minY),
                           control: CGPoint(x: r.minX, y: r.minY))
        }
        p.closeSubpath()
        return p
    }
}

/// A soft wash of the current status colour spilling out from under the notch.
///
/// Idle draws *nothing* — not a transparent layer, no view at all — so a quiet Mac has
/// no extra layer to composite and nothing driving redraws.
struct StatusBloom: View {
    let status: SessionStatus
    let width: CGFloat
    /// Only the lower part clears the notch body, so this is roughly three times the
    /// halo you actually see.
    var height: CGFloat = 62

    /// Slack around the ellipse so the blur can fade to nothing *inside* the rasterised
    /// bounds. Without it `drawingGroup()` cuts the blur off at the frame edge and the
    /// glow gets a visible rectangular seam.
    static let bleed: CGFloat = 55

    @State private var breathing = false

    private var tint: Color? {
        switch status {
        case .working: return Theme.green
        case .waiting: return Theme.amber
        case .error:   return Theme.red
        case .idle:    return nil
        }
    }

    /// Waiting is meant to be noticed, so it sits brighter than a working session.
    private var baseOpacity: Double {
        switch status {
        case .waiting: return 0.46
        case .error:   return 0.44
        default:       return 0.30
        }
    }

    var body: some View {
        if let tint {
            // Captured up front: the keyframe body is a Sendable closure and can't reach
            // back into main-actor state.
            let base = baseOpacity
            Ellipse()
                // Vertical fade, not radial: the glow is a wide wash escaping from under
                // the whole bottom edge, brightest where it meets the body. A radial
                // gradient sized to the height collapses to a small blob in the middle.
                .fill(LinearGradient(colors: [tint, tint.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: height)
                .padding(Self.bleed)
                // Plain alpha, not a lighten blend: the panel is transparent, so there
                // is no backdrop inside the window for a blend mode to work against.
                .blur(radius: 26)
                // Rasterise the blur once. Breathing then rides on opacity alone —
                // animating scale would re-run the blur every frame, which is by far the
                // most expensive thing this app could do sixty times a second.
                .drawingGroup()
                .opacity(breathing ? 1.0 : 0.6)
                // One flare when a session starts needing you, then steady. A repeating
                // blink at the top of the screen would be unbearable.
                .keyframeAnimator(initialValue: 1.0, trigger: status) { view, flare in
                    view.opacity(base * flare)
                } keyframes: { _ in
                    if status == .waiting || status == .error {
                        CubicKeyframe(2.4, duration: 0.14)
                        CubicKeyframe(1.0, duration: 0.55)
                    } else {
                        LinearKeyframe(1.0, duration: 0.01)
                    }
                }
                .allowsHitTesting(false)
                .onAppear { startBreathing() }
                .onChange(of: status) { _, _ in startBreathing() }
        }
    }

    private func startBreathing() {
        guard status == .working, Theme.Motion.loopsAllowed else {
            breathing = false
            return
        }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

/// One 128×128 noise tile, generated once and tiled across the panel. Static by design:
/// animated grain costs a full-surface redraw every frame and, at this size, just reads
/// as interference.
struct GrainOverlay: View {
    var body: some View {
        GrainTexture.image
            .resizable(resizingMode: .tile)
            .opacity(0.03)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

private enum GrainTexture {
    static let image: Image = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in stride(from: 0, to: pixels.count, by: 4) {
            // Cheap deterministic noise; the tile is built once, at first use.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let v = UInt8((seed >> 33) & 0xFF)
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 255
        }
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else {
            return Image(nsImage: NSImage(size: .init(width: 1, height: 1)))
        }
        return Image(decorative: cg, scale: 2)
    }()
}
