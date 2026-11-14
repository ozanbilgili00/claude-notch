import SwiftUI
import Observation

/// Drives the notch's open/closed presentation and the size the window should adopt.
@MainActor
@Observable
final class NotchViewModel {

    enum Presentation: Equatable {
        case closed              // compact status pill
        case expanded            // full panel (hover / click / hotkey)
    }

    var presentation: Presentation = .closed
    /// When true, an external event (permission/question) forced the panel open and
    /// it should not auto-collapse on mouse-out until resolved.
    var lockedOpen: Bool = false

    let notch: ScreenNotch

    init(notch: ScreenNotch) {
        self.notch = notch
    }

    // MARK: Sizing

    /// Closed pill size — hugs the physical notch tightly, with just enough room on
    /// each side for the status + usage clusters.
    var closedSize: CGSize {
        CGSize(width: notch.notchSize.width + 230, height: max(notch.notchSize.height, 30))
    }

    /// Expanded panel size.
    var expandedSize: CGSize {
        CGSize(width: 720, height: 360)
    }

    var currentSize: CGSize {
        presentation == .closed ? closedSize : expandedSize
    }

    /// Slack below the body for the status glow to spill into. The window has to be
    /// taller than the panel or the glow is simply clipped away at the window edge;
    /// the extra strip is transparent and passes clicks through (see NotchPanel).
    static let bloomMargin: CGFloat = 70

    /// Footprint the window always occupies, whatever the presentation.
    var windowFootprint: CGSize {
        // Wider than the panel by one concave fillet on each side: the silhouette's top
        // edge spills that far past the body, and a window sized to the body alone would
        // clip the fillets off.
        CGSize(width: expandedSize.width + 2 * Theme.panelFlare,
               height: expandedSize.height + Self.bloomMargin)
    }

    // MARK: Transitions

    func expand() {
        hoverTask?.cancel()
        guard presentation != .expanded else { return }
        withAnimation(Theme.Motion.open) { presentation = .expanded }
    }

    func collapse(force: Bool = false) {
        hoverTask?.cancel()
        if lockedOpen && !force { return }
        // With auto-collapse off the panel stays put when the pointer leaves; only an
        // explicit close (Done, ⌥Space, Esc) — which passes `force` — puts it away.
        if !force && !UserDefaults.standard.autoCollapse { return }
        guard presentation != .closed else { return }
        withAnimation(Theme.Motion.close) { presentation = .closed }
    }

    // MARK: Hover intent

    private var hoverTask: Task<Void, Never>?
    /// Opening needs a moment of intent so the panel doesn't fly open every time the
    /// pointer crosses the notch on its way to the menu bar. Leaving gets a longer
    /// grace period so a pointer that slips a few pixels off the edge doesn't
    /// slam the panel shut mid-click.
    private static let openDelay: Duration = .milliseconds(120)
    private static let closeDelay: Duration = .milliseconds(250)

    func hoverIntent(_ hovering: Bool) {
        hoverTask?.cancel()
        // Once the panel is open, hovering back into it should never re-trigger a delay.
        if hovering && presentation == .expanded { return }
        let delay = hovering ? Self.openDelay : Self.closeDelay
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if hovering { self.expand() } else { self.collapse() }
        }
    }

    func toggle() {
        if presentation == .closed { expand() } else { collapse(force: true) }
    }

    /// Force the panel open and keep it there (permission / question arrived).
    func forceOpen() {
        lockedOpen = true
        expand()
    }

    func unlockAndMaybeCollapse() {
        lockedOpen = false
    }
}
