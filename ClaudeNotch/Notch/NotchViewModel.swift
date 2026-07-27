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

    // MARK: Transitions

    func expand() {
        guard presentation != .expanded else { return }
        withAnimation(Theme.expandSpring) { presentation = .expanded }
    }

    func collapse(force: Bool = false) {
        if lockedOpen && !force { return }
        // With auto-collapse off the panel stays put when the pointer leaves; only an
        // explicit close (Done, ⌥Space, Esc) — which passes `force` — puts it away.
        if !force && !UserDefaults.standard.autoCollapse { return }
        guard presentation != .closed else { return }
        withAnimation(Theme.expandSpring) { presentation = .closed }
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
