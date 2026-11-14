import SwiftUI
import Observation

/// Drives the edge dock: which rings it shows, where it sits vertically, and whether a
/// bubble or the full panel is open. `NotchViewModel`'s sibling — same job, different edge.
@MainActor
@Observable
final class EdgeViewModel {

    enum Presentation: Equatable {
        case dock                       // just the rings
        case bubble(UsageRingKind)      // rings + the detail card for one of them
        case panel                      // the full panel, right-aligned
    }

    private(set) var presentation: Presentation = .dock
    /// Set while something needs the user (permission / question): the panel stays put
    /// until it is dealt with, exactly as in notch mode.
    var lockedOpen = false

    /// Rings currently drawable, in the order they appear. The window is sized from this,
    /// so it lives here rather than being recomputed in the view.
    var rings: [UsageRingKind] = UsageRingKind.defaults

    /// Distance from the top of the visible screen area down to the top of the dock.
    /// Stored rather than an absolute y so it survives a resolution change (see
    /// `EdgeGeometry.windowOrigin`).
    var offset: CGFloat {
        didSet {
            guard offset != oldValue else { return }
            UserDefaults.standard.set(Double(offset), forKey: Self.offsetKey)
        }
    }

    /// Distance from the top of the window down to the top of the expanded panel. Written
    /// by the controller, which is the only thing that knows where the window sits on the
    /// screen; see `EdgeGeometry.panelTop`.
    var panelTop: CGFloat = 0

    /// True for the duration of a drag. The bubble is closed while dragging — a card that
    /// slides around with a tail chasing a moving ring is noise, not feedback.
    var isDragging = false

    private static let offsetKey = "edgeOffsetY"

    init(offset: CGFloat) {
        self.offset = offset
    }

    /// The saved offset, or nil the first time the dock is ever shown (then it centres).
    static func savedOffset() -> CGFloat? {
        guard UserDefaults.standard.object(forKey: offsetKey) != nil else { return nil }
        return CGFloat(UserDefaults.standard.double(forKey: offsetKey))
    }

    var selectedRing: UsageRingKind? {
        if case .bubble(let kind) = presentation { return kind }
        return nil
    }

    var isPanelOpen: Bool { presentation == .panel }

    // MARK: Transitions

    /// Tapping a ring: opens its bubble, or moves the bubble over from another ring, or
    /// closes it if it was already this one.
    func toggleBubble(_ kind: UsageRingKind) {
        withAnimation(Theme.Motion.quick) {
            presentation = presentation == .bubble(kind) ? .dock : .bubble(kind)
        }
    }

    func closeBubble() {
        guard case .bubble = presentation else { return }
        withAnimation(Theme.Motion.quick) { presentation = .dock }
    }

    func openPanel() {
        guard presentation != .panel else { return }
        withAnimation(Theme.Motion.open) { presentation = .panel }
    }

    func closePanel(force: Bool = false) {
        guard presentation == .panel else { return }
        if lockedOpen && !force { return }
        withAnimation(Theme.Motion.close) { presentation = .dock }
    }

    func togglePanel() {
        if presentation == .panel { closePanel(force: true) } else { openPanel() }
    }

    /// A permission or a question arrived.
    func forceOpen() {
        lockedOpen = true
        openPanel()
    }

    func unlockAndMaybeCollapse() {
        lockedOpen = false
    }

    /// Back to just the rings. Unlike the notch there is nothing to hover here — the dock
    /// is always on screen — so leaving the panel open after the pointer has gone means it
    /// covers half the desktop until something else happens to close it.
    ///
    /// `force` marks an explicit dismissal (a click elsewhere, Escape): those ignore the
    /// auto-collapse preference, which is about the pointer merely wandering off.
    func collapseToDock(force: Bool = false) {
        guard presentation != .dock else { return }
        if lockedOpen { return }
        if !force && !UserDefaults.standard.autoCollapse { return }
        withAnimation(Theme.Motion.close) { presentation = .dock }
    }

    /// Escape: peel one layer off rather than closing everything at once.
    func dismissTopmost() {
        switch presentation {
        case .panel:  closePanel(force: true)
        case .bubble: closeBubble()
        case .dock:   break
        }
    }
}
