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
    private let spotify: SpotifyService
    private let shelf: ShelfStore
    private let web: SpotifyWebAPI
    private let audio: AudioService
    private let lyrics = LyricsService()
    private let artwork = ArtworkLoader()
    private var sizeObservation: AnyCancellable?
    private var lastPresentation: NotchViewModel.Presentation = .closed
    private weak var hostView: PassthroughHostingView<NotchRootView>?

    init(store: SessionStore, spotify: SpotifyService, shelf: ShelfStore,
         web: SpotifyWebAPI, audio: AudioService, screen: NSScreen) {
        self.store = store
        self.spotify = spotify
        self.shelf = shelf
        self.web = web
        self.audio = audio
        let notch = ScreenNotch.resolve(for: screen)
        self.viewModel = NotchViewModel(notch: notch)
        self.panel = NotchPanel(size: viewModel.windowFootprint)

        let root = NotchRootView(store: store, model: viewModel, spotify: spotify,
                                 lyrics: lyrics, artwork: artwork, shelf: shelf, web: web,
                                 audio: audio)
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
        host.interactiveRect = contentRect(for: viewModel.currentSize)

        position(for: viewModel.windowFootprint)
        panel.orderFrontRegardless()

        configureFileDrops()
        observeShelfEnabled()
        observePresentation()
    }

    /// Takes the window off screen. Called when the layout is switched — dropping the last
    /// reference is not enough, because AppKit keeps an ordered-in window alive on its own.
    /// Nothing is open or being answered, so moving the window to another display now
    /// takes nothing away from the user.
    var isIdle: Bool { viewModel.presentation == .closed }

    func close() {
        panel.setFileDropEnabled(false)
        panel.orderOut(nil)
        panel.contentView = nil
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
        hostView?.interactiveRect = contentRect(for: viewModel.currentSize)
        let target = viewModel.currentSize
        animateFrame(to: target)
    }

    /// The notch body is a band across the top of the window; the slack underneath it is
    /// only there for the glow to spill into.
    private func contentRect(for size: CGSize) -> CGRect {
        let footprint = viewModel.windowFootprint
        return CGRect(x: 0, y: footprint.height - size.height,
                      width: footprint.width, height: size.height)
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

    // MARK: File drops

    /// Wires the window-level drop target used while the pill is closed. See the comment
    /// on `NotchPanel`'s dragging extension for why this cannot be a view.
    private func configureFileDrops() {
        panel.setFileDropEnabled(shelf.enabled)
        panel.dropAcceptRect = { [weak self] in
            guard let self else { return .zero }
            return self.dropRect()
        }
        panel.onDragEnter = { [weak self] in
            guard let self else { return }
            // Locked, not merely expanded: the pointer is holding a file and will wander
            // around the panel, and a plain expand would collapse again the moment the
            // hover heuristics decided the pointer had left.
            self.viewModel.forceOpen()
        }
        panel.onDragExit = { [weak self] in
            self?.viewModel.unlockAndMaybeCollapse()
        }
        panel.onDrop = { [weak self] urls in
            guard let self, self.shelf.enabled else { return false }
            let taken = self.shelf.add(urls.filter(\.isFileURL))
            if taken > 0 { self.viewModel.forceOpen() }
            return taken > 0
        }
    }

    /// The setting can be turned off while the app runs, and a window that stays
    /// registered for file drags would keep intercepting them with nowhere to put them.
    private func observeShelfEnabled() {
        func track() {
            withObservationTracking {
                _ = shelf.enabled
            } onChange: {
                Task { @MainActor in
                    self.panel.setFileDropEnabled(self.shelf.enabled)
                    track()
                }
            }
        }
        track()
    }

    /// The window always occupies the expanded footprint, so the drop region has to be
    /// narrowed to whatever is actually drawn: the pill while closed, the panel while open.
    private func dropRect() -> CGRect {
        let size = viewModel.currentSize
        let bounds = panel.contentView?.bounds ?? .zero
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: bounds.height - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: External control

    func toggle() { viewModel.toggle() }
    func expand() { viewModel.expand() }
    func collapse() { viewModel.collapse(force: true) }
}
