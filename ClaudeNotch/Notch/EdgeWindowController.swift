import AppKit
import SwiftUI

/// Owns the panel in edge mode: pins it to the right-hand edge of the screen, moves it when
/// the dock is dragged, and keeps its click-through region in step with what is on screen.
///
/// `NotchWindowController`'s sibling. They share the window class and the hosting view but
/// nothing else: the notch is centred on a piece of hardware and hangs from the menu bar,
/// this one is a free-floating strip whose only fixed point is the screen's right edge.
@MainActor
final class EdgeWindowController {
    private let panel: NotchPanel
    private let viewModel: EdgeViewModel
    private let store: SessionStore
    private let lyrics = LyricsService()
    private let artwork = ArtworkLoader()
    private weak var hostView: PassthroughHostingView<EdgeRootView>?
    private var screen: NSScreen
    private var screenObserver: NSObjectProtocol?
    /// Clicks that land in *another* app. See `observeOutsideClicks()`.
    private var outsideClickMonitor: Any?
    /// Whatever is on screen right now, in screen coordinates, plus the poll that watches
    /// the pointer against it. See `startPointerWatch()`.
    private var interactiveScreenRect: CGRect = .zero
    private var pointerWatch: Timer?
    private var ticksAway = 0
    /// Where inside the dock the pointer grabbed it, so the dock follows the mouse without
    /// jumping to centre itself on the pointer.
    private var dragGrab: CGFloat?

    init(store: SessionStore, spotify: SpotifyService, shelf: ShelfStore,
         web: SpotifyWebAPI, audio: AudioService, screen: NSScreen) {
        self.store = store
        self.screen = screen
        let rings = UsageRingKind.visible(usage: store.usage,
                                          workingCount: store.workingCount,
                                          sessionCount: store.sessions.count)
        let visible = screen.visibleFrame
        let offset = EdgeViewModel.savedOffset()
            ?? EdgeGeometry.centeredOffset(visibleTop: visible.maxY, screen: screen.frame,
                                           ringCount: rings.count)
        self.viewModel = EdgeViewModel(offset: offset)
        self.viewModel.rings = rings
        self.panel = NotchPanel(size: EdgeGeometry.windowSize(ringCount: rings.count))

        let root = EdgeRootView(store: store, model: viewModel, spotify: spotify,
                                lyrics: lyrics, artwork: artwork, shelf: shelf,
                                web: web, audio: audio,
                                onDrag: { [weak self] dragging in
                                    self?.handleDrag(dragging)
                                })
        let host = PassthroughHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        panel.contentView = host
        hostView = host

        reposition()
        panel.orderFrontRegardless()

        observeRings()
        observePresentation()
        observeScreenChanges()
        observeOutsideClicks()
        startPointerWatch()
    }

    /// Takes the window off screen. Called when the layout is switched — dropping the last
    /// reference is not enough, because AppKit keeps an ordered-in window alive on its own.
    func close() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        pointerWatch?.invalidate()
        pointerWatch = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func toggle() { viewModel.togglePanel() }
    func expand() { viewModel.openPanel() }

    /// Focus a session and show it — the same entry point the notch controller offers for
    /// notification taps.
    func focus(_ id: String) {
        store.selectedID = id
        viewModel.openPanel()
    }

    /// Nothing is open, so the dock can move to another display without interrupting.
    var isIdle: Bool { viewModel.presentation == .dock && !viewModel.lockedOpen }

    // MARK: Placement

    private func reposition() {
        let size = EdgeGeometry.windowSize(ringCount: viewModel.rings.count)
        let visible = screen.visibleFrame
        viewModel.offset = EdgeGeometry.clampedOffset(viewModel.offset,
                                                      visibleTop: visible.maxY,
                                                      screen: screen.frame,
                                                      ringCount: viewModel.rings.count)
        let origin = EdgeGeometry.windowOrigin(screen: screen.frame,
                                               visibleTop: visible.maxY,
                                               offset: viewModel.offset,
                                               ringCount: viewModel.rings.count)
        viewModel.panelTop = EdgeGeometry.panelTop(windowTop: origin.y + size.height,
                                                   windowHeight: size.height,
                                                   visibleTop: visible.maxY,
                                                   visibleBottom: visible.minY)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        updateInteractiveRect(windowSize: size)
        if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" {
            fputs("[edge] screen=\(screen.frame) visible=\(visible) rings=\(viewModel.rings.count) " +
                  "frame=\(panel.frame) visible=\(panel.isVisible)\n", stderr)
        }
    }

    /// The window is much larger than what is drawn in it; everything outside this
    /// rectangle passes clicks through to whatever is behind (see `NotchPanel`).
    private func updateInteractiveRect(windowSize size: CGSize) {
        let dockHeight = EdgeGeometry.dockHeight(ringCount: viewModel.rings.count)
        let dockTop = (size.height - dockHeight) / 2
        // AppKit measures from the bottom-left; the layout above measures from the top.
        var rect = CGRect(x: size.width - EdgeGeometry.bleed - EdgeGeometry.dockWidth,
                          y: size.height - dockTop - dockHeight,
                          width: EdgeGeometry.dockWidth,
                          height: dockHeight)

        switch viewModel.presentation {
        case .dock:
            break
        case .bubble:
            // The whole strip beside the dock: the card's exact height is decided by
            // SwiftUI as it lays the text out, and a rectangle that lags a frame behind
            // would drop the first click on it.
            rect = rect.union(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        case .panel:
            // The panel plus the dock, not the whole window: the window carries `bleed`
            // slack on every side for shadows, and claiming that too would eat desktop
            // clicks along a strip the user can see straight through.
            rect = rect.union(CGRect(
                x: size.width - EdgeGeometry.bleed - EdgeGeometry.dockWidth
                    - EdgeGeometry.panelSize.width,
                y: size.height - viewModel.panelTop - EdgeGeometry.panelSize.height,
                width: EdgeGeometry.panelSize.width,
                height: EdgeGeometry.panelSize.height))
        }
        hostView?.interactiveRect = rect
        interactiveScreenRect = rect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        // Never SwiftUI-based pass-through here. `NSHostingView` answers a hit anywhere in
        // its own bounds with *itself*, which that path reads as "nothing was hit" and
        // discards — fine for the notch pill, which only ever reacts to hover, but it would
        // swallow every click on a ring. The rectangle above is the pass-through rule.
        hostView?.passthroughEnabled = false
    }

    /// Dragging the grip moves the window itself.
    ///
    /// The pointer is read from `NSEvent.mouseLocation` rather than from the gesture's own
    /// translation, and that is the whole trick: a SwiftUI drag reports movement relative to
    /// the view it is in, and this view is inside the window being moved. Measuring against
    /// a frame that runs away from you makes the dock lag the pointer by roughly half the
    /// distance travelled.
    private func handleDrag(_ dragging: Bool) {
        let visibleTop = screen.visibleFrame.maxY
        guard dragging else {
            dragGrab = nil
            return
        }
        // Distance from the top of the usable screen down to the pointer.
        let pointer = visibleTop - NSEvent.mouseLocation.y
        let grab = dragGrab ?? (pointer - viewModel.offset)
        dragGrab = grab
        viewModel.offset = EdgeGeometry.clampedOffset(pointer - grab,
                                                      visibleTop: visibleTop,
                                                      screen: screen.frame,
                                                      ringCount: viewModel.rings.count)
        reposition()
    }

    // MARK: Observation

    /// The set of rings changes with the settings *and* with the data — a plan that starts
    /// reporting an Opus window grows a ring without anyone touching a switch — and the
    /// window's height is derived from it.
    private func observeRings() {
        func track() {
            withObservationTracking {
                _ = store.usage
                _ = store.sessions.count
            } onChange: {
                Task { @MainActor in
                    self.refreshRings()
                    track()
                }
            }
        }
        track()
    }

    func refreshRings() {
        let rings = UsageRingKind.visible(usage: store.usage,
                                          workingCount: store.workingCount,
                                          sessionCount: store.sessions.count)
        guard rings != viewModel.rings else { return }
        viewModel.rings = rings
        if let selected = viewModel.selectedRing, !rings.contains(selected) {
            viewModel.closeBubble()
        }
        reposition()
    }

    private func observePresentation() {
        func track() {
            withObservationTracking {
                _ = viewModel.presentation
            } onChange: {
                Task { @MainActor in
                    self.updateInteractiveRect(
                        windowSize: EdgeGeometry.windowSize(ringCount: self.viewModel.rings.count))
                    track()
                }
            }
        }
        track()
    }

    /// Clicking somewhere else puts the panel away.
    ///
    /// Unlike the notch, this panel is opened by a click and not by hover, so nothing else
    /// would ever close it: the pointer can leave, another app can come forward, and a
    /// 720pt panel would still be sitting over the desktop passing clicks through to it.
    /// The in-window catcher in `EdgeRootView` only sees clicks inside this window, which
    /// is exactly the case this covers — a global monitor sees the ones that aren't.
    private func observeOutsideClicks() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewModel.presentation != .dock else { return }
                // A global monitor only ever reports events delivered elsewhere, so
                // reaching here already means the click missed this window.
                self.viewModel.collapseToDock(force: true)
            }
        }
    }

    /// Puts the panel away once the pointer has left it, the way the notch collapses on
    /// mouse-out.
    ///
    /// Polled rather than hovered: SwiftUI's `onHover` only ever reports leaving something
    /// it reported entering, and a bubble is opened by clicking a *ring* — the pointer is
    /// on the dock the whole time and never enters the card, so no exit is ever delivered
    /// and the card stays up forever. Reading the pointer needs no such handshake. Two
    /// ticks of grace so clipping a corner on the way to the dock doesn't shut it.
    private func startPointerWatch() {
        pointerWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.viewModel.presentation != .dock, !self.viewModel.isDragging else {
                    self.ticksAway = 0
                    return
                }
                let margin: CGFloat = 8
                if self.interactiveScreenRect.insetBy(dx: -margin, dy: -margin)
                    .contains(NSEvent.mouseLocation) {
                    self.ticksAway = 0
                } else {
                    self.ticksAway += 1
                    if self.ticksAway >= 2 {
                        self.ticksAway = 0
                        self.viewModel.collapseToDock()
                    }
                }
            }
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Same display, new geometry (resolution, arrangement). A change of display
                // is AppDelegate's call: it rebuilds the layout on the right one.
                if let same = NSScreen.screens.first(where: {
                    ScreenPicker.displayID($0) == ScreenPicker.displayID(self.screen)
                }) {
                    self.screen = same
                }
                self.reposition()
            }
        }
    }
}
