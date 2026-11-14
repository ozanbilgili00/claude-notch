import AppKit
import SwiftUI

/// The dock's grip: drag it to move the dock, click it to open the panel.
///
/// AppKit rather than a SwiftUI `DragGesture`, for the same reason `FileDragHandle` is
/// AppKit — measured, not assumed. Inside this non-activating panel a SwiftUI drag gesture
/// never starts: taps arrive, `mouseDragged` never reaches the gesture, and the dock simply
/// refused to move. An `NSView` handling the three mouse events directly does work, and it
/// also makes the click-versus-drag decision explicit instead of leaving it to gesture
/// arbitration.
struct EdgeGripHandle: NSViewRepresentable {
    /// Called on every step of a drag with true, and once with false when it ends.
    var onDrag: (Bool) -> Void
    /// A press that never turned into a drag.
    var onClick: () -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.configure(with: self)
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.configure(with: self)
    }

    final class GripView: NSView {
        private var handle: EdgeGripHandle?
        /// Set the moment the pointer moves far enough, so the mouse-up that ends a drag is
        /// not also read as a click on the grip.
        private var dragged = false
        private var tracker: Timer?
        private var pressOrigin: NSPoint = .zero

        func configure(with handle: EdgeGripHandle) {
            self.handle = handle
        }

        deinit { tracker?.invalidate() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


        /// Mouse-down arrives; `mouseDragged` does not.
        ///
        /// Measured, not assumed: with a log on all three handlers, this panel receives
        /// `hitTest` and `mouseDown` and never a single `mouseDragged` — and a SwiftUI
        /// `DragGesture` in the same place never fires either. A non-activating panel that
        /// never becomes key is not given the drag stream. So the gesture is followed by
        /// polling the pointer instead: `NSEvent.mouseLocation` and `pressedMouseButtons`
        /// are global state and do not depend on anything being routed to us.
        override func mouseDown(with event: NSEvent) {
            dragged = false
            pressOrigin = NSEvent.mouseLocation
            tracker?.invalidate()
            tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated { self?.tick(timer) }
            }
        }

        private func tick(_ timer: Timer) {
            let held = NSEvent.pressedMouseButtons & 1 != 0
            let moved = abs(NSEvent.mouseLocation.y - pressOrigin.y) > 2
                || abs(NSEvent.mouseLocation.x - pressOrigin.x) > 2

            if held {
                guard moved else { return }
                dragged = true
                handle?.onDrag(true)
                return
            }

            timer.invalidate()
            tracker = nil
            if dragged { handle?.onDrag(false) } else { handle?.onClick() }
            dragged = false
        }
    }
}
