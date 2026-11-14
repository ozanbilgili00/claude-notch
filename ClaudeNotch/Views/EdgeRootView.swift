import SwiftUI

/// Root of the edge layout: the dock hard against the screen edge, a detail bubble that
/// pops out to its left, and the full panel when it is asked for.
///
/// Everything is laid out from the window's trailing edge inwards, because that edge is the
/// only fixed point — the window is deliberately wider than the dock so the bubble and the
/// panel have somewhere to appear without a window resize mid-animation.
struct EdgeRootView: View {
    @Bindable var store: SessionStore
    @Bindable var model: EdgeViewModel
    @Bindable var spotify: SpotifyService
    @Bindable var lyrics: LyricsService
    @Bindable var artwork: ArtworkLoader
    @Bindable var shelf: ShelfStore
    @Bindable var web: SpotifyWebAPI
    @Bindable var audio: AudioService
    var onDrag: (Bool) -> Void

    @Namespace private var ns
    /// Measured, not assumed: the card's height depends on its text, which depends on the
    /// language and on whether the ring has a reset time.
    @State private var bubbleHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // A click inside the window but off whatever is open dismisses it. Only
                // present while something *is* open, so the rest of the time this view
                // claims nothing (and the desktop keeps its clicks).
                if model.presentation != .dock {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { model.collapseToDock(force: true) }
                }

                if model.isPanelOpen { panel(in: geometry.size) }
                if let kind = model.selectedRing { bubble(kind, in: geometry.size) }

                EdgeDockView(store: store, model: model, onDrag: onDrag)
                    .padding(.trailing, EdgeGeometry.bleed)
                    .padding(.top, dockTop(in: geometry.size))
            }
            // The alignment is not decoration: without it the frame centres the stack's
            // intrinsic size (a 90pt dock) inside an 810pt window, which parked the dock
            // half a panel away from the edge it is supposed to be glued to.
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .topTrailing)
        }
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(.all, edges: .all)
        .onChange(of: store.blockingSession?.id) { _, blocking in
            if blocking != nil {
                store.selectedID = blocking
                model.forceOpen()
            } else {
                model.unlockAndMaybeCollapse()
            }
        }
        .onAppear { if store.blockingSession != nil { model.forceOpen() } }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            model.dismissTopmost()
            return .handled
        }
    }

    // MARK: Pieces

    /// The dock is centred in the window; the window is what moves when the user drags.
    private func dockTop(in size: CGSize) -> CGFloat {
        max(0, (size.height - EdgeGeometry.dockHeight(ringCount: model.rings.count)) / 2)
    }

    private func bubble(_ kind: UsageRingKind, in size: CGSize) -> some View {
        let index = model.rings.firstIndex(of: kind) ?? 0
        let placement = EdgeGeometry.bubblePlacement(
            ringIndex: index,
            ringCount: model.rings.count,
            bubbleHeight: bubbleHeight,
            windowHeight: size.height,
            dockTopInWindow: dockTop(in: size))
        let progress = kind.progress(usage: store.usage,
                                     workingCount: store.workingCount,
                                     sessionCount: store.sessions.count) ?? 0
        let tint = kind.tint(progress: progress, status: store.aggregateStatus)

        return EdgeBubbleView(kind: kind,
                              progress: progress,
                              tint: tint,
                              resetsIn: kind.resetsIn(usage: store.usage),
                              subtitle: kind == .sessions ? sessionsSummary : nil)
            .frame(width: EdgeGeometry.bubbleWidth)
            .background {
                GeometryReader { proxy in
                    let shape = BubbleShape(tailCenterY: placement.tailY)
                    shape.fill(Theme.surface)
                        .overlay { shape.stroke(Theme.stroke, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                        .onAppear { bubbleHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, new in bubbleHeight = new }
                }
            }
            .padding(.trailing, EdgeGeometry.bleed + EdgeGeometry.dockWidth + EdgeGeometry.bubbleGap)
            .padding(.top, dockTop(in: size) + placement.top)
            // Grows out of its own tail rather than out of its middle, so it reads as
            // coming from the ring that was tapped.
            .transition(.scale(scale: 0.92, anchor: .trailing).combined(with: .opacity))
            .animation(Theme.Motion.quick, value: placement.tailY)
    }

    /// Rounded where the panel ends in mid-air, square where the dock carries on: the two
    /// meet edge to edge, and a rounded corner there would draw a seam between them.
    private var panelShape: some InsettableShape {
        UnevenRoundedRectangle(topLeadingRadius: Theme.panelCorner,
                               bottomLeadingRadius: Theme.panelCorner,
                               bottomTrailingRadius: 0,
                               topTrailingRadius: 0,
                               style: .continuous)
    }

    private var sessionsSummary: String {
        let working = store.workingCount
        guard working > 0 else { return L(.edgeSessionsIdle) }
        return Lcount(.edgeSessionsWorkingOne, .edgeSessionsWorkingMany, working)
    }

    private func panel(in size: CGSize) -> some View {
        ExpandedView(store: store, spotify: spotify, lyrics: lyrics, artwork: artwork,
                     shelf: shelf, web: web, audio: audio, ns: ns,
                     // No camera housing on this edge, so the header needs no gap.
                     headerGap: 0,
                     holdOpen: { hold in
                         if hold { model.lockedOpen = true } else { model.unlockAndMaybeCollapse() }
                     },
                     close: { model.closePanel(force: true) })
            .frame(width: EdgeGeometry.panelSize.width, height: EdgeGeometry.panelSize.height)
            .background {
                // Not the dock's own silhouette: that shape insets its fill by `flare` at
                // the top and bottom, because the dock hangs off the screen edge and needs
                // room for the concave fillets. Behind a panel it meant the header row —
                // mascot, usage, the window buttons — was painted in the strip *above* the
                // black, floating over the desktop with the weekly counter spilling past
                // the corner. The panel is a card butted against the dock, so it fills its
                // frame: rounded on the free side, square where the dock continues it.
                panelShape.fill(Theme.ink)
                    .overlay { panelShape.strokeBorder(Theme.stroke, lineWidth: 1) }
            }
            .padding(.trailing, EdgeGeometry.bleed + EdgeGeometry.dockWidth)
            .padding(.top, model.panelTop)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}
