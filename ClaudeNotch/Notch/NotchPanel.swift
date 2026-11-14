import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats at the notch, above the menu bar,
/// on every Space. Clicks on its transparent regions fall through to whatever is behind.
final class NotchPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .init(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Keep the app from stealing focus when the notch appears.
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    // MARK: File drops (see the NSDraggingDestination extension below)

    /// Region of the window, in window coordinates, that accepts a file drop. Supplied as
    /// a closure because it changes with the presentation and the caller owns that state.
    var dropAcceptRect: (() -> CGRect)?
    /// Called while a file drag hovers the accept region — used to open the panel.
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    /// Returns true if the files were taken.
    var onDrop: (([URL]) -> Bool)?

    // Allow the borderless panel to receive keyboard input (question shortcuts) if needed.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that passes clicks through everywhere except its opaque content.
/// The SwiftUI content is responsible for drawing only where it wants hits; we ask
/// SwiftUI's own hit-testing and return nil (pass-through) when it declines.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Force zero safe-area insets so SwiftUI content draws flush into the notch /
    /// menu-bar region instead of being pushed down by the display's top inset.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// Only pass-through while the compact pill is showing (so clicks around the
    /// small pill reach the desktop/menu bar behind it). While expanded, the panel
    /// is a normal interactive surface — transparency-based pass-through there can
    /// eat clicks on buttons that sit over even slightly-transparent pixels (glyph
    /// gaps, spacer padding), so we disable it and use plain AppKit hit-testing.
    var passthroughEnabled: Bool = true

    /// The part of the view that is actually there, in the view's own (bottom-left origin)
    /// coordinates. The window is deliberately larger than its content — the notch reserves
    /// room below for the status glow, the edge dock reserves room to its left for the
    /// bubble and the panel — and every point outside this rectangle must fall through to
    /// whatever is behind, or the app quietly eats desktop clicks over a large invisible
    /// area.
    var interactiveRect: CGRect?

    /// Take the first click, rather than spending it on activating a window that never
    /// activates. Without this the first tap on the edge dock after launch — or after any
    /// other app has been in front — is swallowed by AppKit's "click to focus" rule and
    /// the ring simply doesn't respond.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let interactiveRect, !interactiveRect.contains(point) { return nil }
        guard passthroughEnabled else { return super.hitTest(point) }
        let result = super.hitTest(point)
        // If the deepest hit is the hosting view's background itself, pass through.
        if result === self { return nil }
        return result
    }
}

// MARK: - File drops

/// Dropping files onto the *closed* notch has to be handled by the window, not by a view.
///
/// While the pill is showing, `PassthroughHostingView.hitTest` deliberately returns nil for
/// everything that isn't opaque content, so clicks fall through to the desktop — and AppKit
/// finds drag destinations by hit-testing too, which means no view under the pointer ever
/// gets offered the drag. `NSWindow` itself conforms to `NSDraggingDestination` and is
/// consulted only when no view claims the drag, so it can accept the drop without any view
/// having to start swallowing clicks.
///
/// The conformance is spelled out: in Swift `NSWindow` does not declare
/// `NSDraggingDestination` (it is an informal protocol on the ObjC side), so these read as
/// plain methods rather than overrides, and without the conformance they would never be
/// exposed to the runtime for AppKit to call.
///
/// Once the panel is expanded the hosting view stops passing clicks through, SwiftUI's own
/// drop destination claims the drag first, and none of this runs.
extension NotchPanel: NSDraggingDestination {

    /// Registers (or unregisters) the window as a file-drop target.
    func setFileDropEnabled(_ enabled: Bool) {
        if enabled {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    /// Only the notch body itself accepts. The window is always as large as the *expanded*
    /// panel — mostly invisible while closed — so without this a file dropped anywhere in a
    /// 720×430 transparent rectangle would be swallowed.
    private func acceptsDrag(at point: NSPoint) -> Bool {
        guard let rect = dropAcceptRect?() else { return false }
        return rect.contains(point)
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        debugDrag("entered", sender)
        guard acceptsDrag(at: sender.draggingLocation), !urls(from: sender).isEmpty else {
            return []
        }
        onDragEnter?()
        return .copy
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(at: sender.draggingLocation), !urls(from: sender).isEmpty else {
            return []
        }
        // Re-announced on every update: a drag that leaves the accept rect and comes back
        // gets no second `draggingEntered`, so the panel would stay shut.
        onDragEnter?()
        return .copy
    }

    public func draggingExited(_ sender: NSDraggingInfo?) {
        debugDrag("exited", sender)
        onDragExit?()
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(from: sender)
        debugDrag("perform \(files.count) file(s)", sender)
        guard !files.isEmpty else { return false }
        return onDrop?(files) ?? false
    }

    public func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    private func debugDrag(_ label: String, _ sender: NSDraggingInfo?) {
        guard ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" else { return }
        let point = sender?.draggingLocation ?? .zero
        fputs("[drop] \(label) at \(point) accept=\(String(describing: dropAcceptRect?()))\n", stderr)
    }
}
