import AppKit
import SwiftUI
import Combine

/// Owns the notch panel: creates it, hosts the SwiftUI root, keeps it pinned to the
/// top-center of the notched screen, and resizes it when the presentation changes.
@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let viewModel: NotchViewModel
    private let store: SessionStore
    private var sizeObservation: AnyCancellable?
    private var lastPresentation: NotchViewModel.Presentation = .closed
    private weak var hostView: PassthroughHostingView<NotchRootView>?

    init(store: SessionStore) {
        self.store = store
        let notch = ScreenNotch.primary()
        self.viewModel = NotchViewModel(notch: notch)
        self.panel = NotchPanel(size: viewModel.windowFootprint)

        let root = NotchRootView(store: store, model: viewModel)
        let host = PassthroughHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        // Draw into the notch/menu-bar region: don't let the safe area inset push
        // our content down below the physical notch.
        if #available(macOS 13.3, *) {
            host.safeAreaRegions = []
        }
        panel.contentView = host
        hostView = host
        host.passthroughEnabled = viewModel.presentation == .closed
        host.contentHeight = viewModel.currentSize.height

        position(for: viewModel.windowFootprint)
        panel.orderFrontRegardless()

        observePresentation()
    }

    /// Poll the view model's presentation each frame-ish and resize the window to match.
    /// (Observation → Combine bridge kept simple: a display-linked timer is overkill;
    /// we react on the same runloop the animations run on.)
    private func observePresentation() {
        // Use withObservationTracking to react to presentation changes.
        func track() {
            withObservationTracking {
                _ = viewModel.presentation
            } onChange: {
                Task { @MainActor in
                    self.handlePresentationChange()
                    track()
                }
            }
        }
        track()
    }

    private func handlePresentationChange() {
        guard viewModel.presentation != lastPresentation else { return }
        lastPresentation = viewModel.presentation
        hostView?.passthroughEnabled = viewModel.presentation == .closed
        hostView?.contentHeight = viewModel.currentSize.height
        let target = viewModel.currentSize
        animateFrame(to: target)
    }

    /// Keep the window big enough to contain the expanded panel at all times so the
    /// SwiftUI content can animate freely; we still recenter on the notch.
    private func position(for size: CGSize) {
        // Always reserve the expanded footprint (plus glow slack); content is
        // top-anchored & centered.
        let footprint = viewModel.windowFootprint
        let screen = viewModel.notch.screen.frame
        let x = screen.midX - footprint.width / 2
        let y = screen.maxY - footprint.height
        panel.setFrame(NSRect(x: x, y: y, width: footprint.width, height: footprint.height),
                       display: true)
        if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" {
            fputs("[notch] screen.frame=\(screen) panel.frame=\(panel.frame) " +
                  "contentView.bounds=\(String(describing: panel.contentView?.bounds))\n", stderr)
        }
    }

    private func animateFrame(to size: CGSize) {
        // Content resizes itself via SwiftUI; the window stays at expanded footprint,
        // so there is nothing to animate at the window level. Kept as a hook for
        // future per-size window shaping.
        position(for: size)
    }

    // MARK: External control

    func toggle() { viewModel.toggle() }
    func expand() { viewModel.expand() }
    func collapse() { viewModel.collapse(force: true) }
}
