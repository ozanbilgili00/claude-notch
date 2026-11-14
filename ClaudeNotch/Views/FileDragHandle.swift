import AppKit
import SwiftUI

/// The interactive surface of a shelf row: click to open, drag to hand the file to
/// another app, right-click for the row's menu.
///
/// AppKit rather than SwiftUI's `.onDrag` for one measured reason. `.onDrag` materialises
/// whatever provider it is given into `~/Library/Caches/com.apple.SwiftUI.Drag-<uuid>/`
/// and hands the receiver *that* copy — dropping a shelf item into a terminal pasted the
/// cache path, not the file's own. `NSItemProvider(contentsOf:)` behaves the same way; the
/// copy is SwiftUI's, not the provider's. An `NSURL` written straight onto a dragging
/// session's pasteboard carries the real path, which is the whole point of a shelf that
/// exists to hand out file paths.
struct FileDragHandle: NSViewRepresentable {
    let url: URL
    let icon: NSImage
    var onOpen: () -> Void
    var onReveal: () -> Void
    var onRemove: () -> Void
    /// True while a drag session is in flight, so the panel can be held open.
    var onDragSession: (Bool) -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.configure(with: self)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.configure(with: self)
    }

    final class DragView: NSView, NSDraggingSource {
        private var handle: FileDragHandle?
        /// Set the moment a drag begins so the matching mouse-up isn't also read as a
        /// click — otherwise every drag would open the file as well as hand it over.
        private var draggedThisGesture = false
        private var tracking: NSTrackingArea?

        func configure(with handle: FileDragHandle) {
            self.handle = handle
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // The row's hover highlight lives in SwiftUI, but this view sits on top of it
            // and swallows the mouse, so the hover has to be reported from here.
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { handle?.onHover(true) }
        override func mouseExited(with event: NSEvent) { handle?.onHover(false) }

        override func mouseDown(with event: NSEvent) {
            draggedThisGesture = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !draggedThisGesture, let handle else { return }
            draggedThisGesture = true

            let item = NSDraggingItem(pasteboardWriter: handle.url as NSURL)
            item.setDraggingFrame(bounds, contents: handle.icon)
            handle.onDragSession(true)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            guard !draggedThisGesture else { return }
            handle?.onOpen()
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let handle else { return nil }
            let menu = NSMenu()
            menu.addItem(MenuItem(title: L(.shelfReveal), action: handle.onReveal))
            menu.addItem(MenuItem(title: L(.shelfRemove), action: handle.onRemove))
            return menu
        }

        // MARK: NSDraggingSource

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // `.copy` in both contexts: the shelf holds a reference, so handing the file to
            // another app must never move or delete the original.
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            handle?.onDragSession(false)
            draggedThisGesture = false
        }
    }
}

/// An `NSMenuItem` that runs a closure, so the menu can be built from SwiftUI actions
/// without a coordinator object per row.
private final class MenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
