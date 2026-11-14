import SwiftUI

/// The black sliver against the screen edge: a grip, then one ring per readout.
struct EdgeDockView: View {
    @Bindable var store: SessionStore
    @Bindable var model: EdgeViewModel
    /// Called with true on every step of a drag and false when it ends. Only the fact of
    /// the drag is reported: the window controller reads the pointer itself, because a
    /// translation measured inside a moving window lags the pointer.
    var onDrag: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            grip
            EdgeStatusHead(store: store, open: { model.openPanel() })
            ForEach(model.rings) { kind in
                ring(kind)
            }
        }
        // The fillets are part of the silhouette, not spare room: content laid out over
        // them prints outside the black.
        .padding(.vertical, EdgeGeometry.dockPadding + EdgeGeometry.flare)
        .frame(width: EdgeGeometry.dockWidth,
               height: EdgeGeometry.dockHeight(ringCount: model.rings.count))
        .background {
            EdgeBackgroundShape(innerCorner: Theme.panelCorner, flare: EdgeGeometry.flare)
                .fill(Theme.ink)
                .overlay {
                    EventSweep(event: store.event, vertical: true)
                        .clipShape(EdgeBackgroundShape(innerCorner: Theme.panelCorner,
                                                       flare: EdgeGeometry.flare))
                }
        }
        .eventNudge(store.event, anchor: .trailing)
    }

    /// Drag it to move the dock, click it to open the panel. Both live on the same handle
    /// because it is the one part of the dock that isn't a ring, and a dock you can't grab
    /// anywhere is a dock you can't move.
    ///
    /// One gesture, not a tap plus a drag: with two, SwiftUI has to decide which of them a
    /// mouse-down belongs to, and here it decided the tap did — the drag never started at
    /// all. Measuring the movement ourselves makes the distinction ours to make.
    /// Drag it to move the dock, click it to open the panel. Both live on the same handle
    /// because it is the one part of the dock that isn't a ring, and a dock you can't grab
    /// anywhere is a dock you can't move. The mouse handling itself is AppKit's — see
    /// `EdgeGripHandle` for why.
    /// Nothing is drawn here any more. The grey capsule that used to mark the handle was
    /// the one bright thing on an otherwise black sliver, and against the desktop it read
    /// as a stray line rather than as something to grab. The handle itself stays: this
    /// strip still drags the dock and still opens the panel on a click.
    private var grip: some View {
        ZStack {
            EdgeGripHandle(
                onDrag: { dragging in
                    if dragging, !model.isDragging {
                        model.isDragging = true
                        model.closeBubble()
                    }
                    if !dragging { model.isDragging = false }
                    onDrag(dragging)
                },
                onClick: { model.togglePanel() }
            )
            // An `NSView` has no intrinsic size, so a representable without an explicit
            // frame is handed 0×0 and never sees a click — which is exactly how this grip
            // managed to be invisible to the mouse while looking perfectly fine.
            .frame(width: EdgeGeometry.dockWidth, height: EdgeGeometry.gripHeight)
        }
        .frame(width: EdgeGeometry.dockWidth, height: EdgeGeometry.gripHeight)
        .help(L(.edgeOpenPanel))
    }

    private func ring(_ kind: UsageRingKind) -> some View {
        let progress = kind.progress(usage: store.usage,
                                     workingCount: store.workingCount,
                                     sessionCount: store.sessions.count) ?? 0
        return EdgeRing(kind: kind,
                        progress: progress,
                        tint: kind.tint(progress: progress, status: store.aggregateStatus),
                        selected: model.selectedRing == kind)
            .onTapGesture { model.toggleBubble(kind) }
    }
}
