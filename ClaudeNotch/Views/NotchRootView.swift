import SwiftUI

/// Root of the notch content. Draws the black notch shape and swaps between the closed
/// pill and the expanded panel with a Dynamic-Island-style spring, top-anchored and
/// horizontally centered under the physical notch.
struct NotchRootView: View {
    @Bindable var store: SessionStore
    @Bindable var model: NotchViewModel

    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            content
                .background(notchShape)
                .onHover { hovering in
                    if hovering { model.expand() }
                    else { model.collapse() }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all, edges: .all)
        // React to blocking events by forcing the panel open.
        .onChange(of: store.blockingSession?.id) { _, newValue in
            if newValue != nil { model.forceOpen() }
            else { model.unlockAndMaybeCollapse() }
        }
        .onAppear {
            if store.blockingSession != nil { model.forceOpen() }
            if ProcessInfo.processInfo.environment["NOTCH_START_EXPANDED"] == "1" {
                model.expand()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case .closed:
            ClosedStateView(store: store, notchWidth: model.notch.notchSize.width, ns: ns)
                .frame(width: model.closedSize.width, height: model.closedSize.height)
        case .expanded:
            ExpandedView(store: store, model: model, ns: ns)
                .frame(width: model.expandedSize.width, height: model.expandedSize.height)
        }
    }

    /// The notch body: black, with the two bottom corners rounded like the hardware notch
    /// when closed, and a full rounded panel when expanded.
    private var notchShape: some View {
        let isClosed = model.presentation == .closed
        let corner = isClosed ? Theme.notchCorner : Theme.panelCorner
        let shape = NotchBackgroundShape(bottomCorner: corner,
                                         topCorner: isClosed ? 0 : Theme.panelCorner)
        return shape
            .fill(Color.black)
            // Border only when expanded; the closed pill is pure black, no outline.
            .overlay {
                if !isClosed { shape.strokeBorder(Theme.stroke, lineWidth: 1) }
            }
            .shadow(color: .black.opacity(isClosed ? 0 : 0.5), radius: 24, y: 12)
    }
}

/// Rounded-bottom (and optionally rounded-top) shape for the notch/panel body.
struct NotchBackgroundShape: InsettableShape {
    var bottomCorner: CGFloat
    var topCorner: CGFloat
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> some InsettableShape {
        var c = self; c.inset += amount; return c
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        let tc = min(topCorner, r.height / 2)
        let bc = min(bottomCorner, r.height / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        // top edge with optional rounded top corners
        if tc > 0 {
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addRoundedRect(in: r, cornerSize: CGSize(width: tc, height: tc))
            return p
        }
        // Closed pill: square top (flush with screen edge), rounded bottom corners.
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bc))
        p.addQuadCurve(to: CGPoint(x: r.maxX - bc, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + bc, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - bc),
                       control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
