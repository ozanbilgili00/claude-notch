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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        // If the deepest hit is the hosting view's background itself, pass through.
        if result === self { return nil }
        return result
    }
}
