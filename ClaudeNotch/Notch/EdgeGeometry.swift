import CoreGraphics

/// Every measurement the edge dock needs, with no view and no screen attached.
///
/// Kept separate from the window controller on purpose: window code can only be checked by
/// looking at it, while this is arithmetic that can be tested. The awkward cases live here
/// too — an empty dock, a drag that would push the dock off-screen, a bubble taller than
/// the dock it points at.
enum EdgeGeometry {

    // MARK: Fixed metrics

    /// Width of the black sliver against the screen edge.
    static let dockWidth: CGFloat = 66
    /// Vertical space one ring occupies, including its percentage caption.
    static let ringSlot: CGFloat = 62
    /// Padding above the first ring and below the last.
    static let dockPadding: CGFloat = 12
    /// The concave fillets where the dock's top and bottom edges turn into the screen edge.
    ///
    /// Content has to clear them: the silhouette's fill is inset by this much on the free
    /// side, so a ring caption laid out against the dock's frame ends up printed outside
    /// the black — which is how the weekly percentage came to hang off the bottom. Lives
    /// here rather than in `Theme` so the height calculation and the shape cannot disagree.
    static let flare: CGFloat = 22
    /// The grip at the top of the dock: drag it to move, click it to open the panel.
    static let gripHeight: CGFloat = 18
    /// The status head under the grip: what the sessions are doing right now. Not optional
    /// like the rings — it is the reason the app exists, and a dock that can only tell you
    /// how much quota is left is a dock you have to open to learn anything.
    static let statusHeight: CGFloat = 44

    /// The bubble and the gap between it and the dock.
    static let bubbleWidth: CGFloat = 268
    static let bubbleGap: CGFloat = 10
    /// How far the tail sticks out of the bubble's right edge.
    static let tailWidth: CGFloat = 11
    static let tailHeight: CGFloat = 20

    /// The expanded panel, same size as in notch mode so one layout serves both.
    static let panelSize = CGSize(width: 720, height: 360)

    /// Slack around the dock so a shadow or glow is not clipped at the window edge.
    static let bleed: CGFloat = 24

    // MARK: Dock

    /// Height of the dock for a given number of rings. An empty dock is still the grip —
    /// switching every ring off should leave something to grab, not a void.
    static func dockHeight(ringCount: Int) -> CGFloat {
        let rings = CGFloat(max(0, ringCount)) * ringSlot
        return gripHeight + statusHeight + rings + 2 * (dockPadding + flare)
    }

    static func dockSize(ringCount: Int) -> CGSize {
        CGSize(width: dockWidth, height: dockHeight(ringCount: ringCount))
    }

    /// Centre of ring `index` measured from the top of the dock. This is the single source
    /// of truth for where a ring sits *and* where its bubble tail points; computing them
    /// separately is how a tail ends up half a ring off.
    static func ringCenterY(index: Int, ringCount: Int) -> CGFloat {
        guard ringCount > 0 else { return dockHeight(ringCount: 0) / 2 }
        let clamped = max(0, min(index, ringCount - 1))
        return flare + dockPadding + gripHeight + statusHeight
            + (CGFloat(clamped) + 0.5) * ringSlot
    }

    // MARK: Window

    /// The window is always as large as the widest thing it may need to show, and the
    /// content is anchored inside it. Resizing a non-activating panel mid-animation is
    /// visibly worse than reserving the space once.
    static func windowSize(ringCount: Int) -> CGSize {
        let dock = dockHeight(ringCount: ringCount)
        let width = panelSize.width + dockWidth + bleed
        let height = max(dock, panelSize.height) + 2 * bleed
        return CGSize(width: width, height: height)
    }

    /// Where the window's bottom-left corner goes, given the screen and the user's saved
    /// vertical offset. `offset` is the distance from the top of the visible area down to
    /// the top of the dock, which is how a person thinks about it ("a bit below the menu
    /// bar"), and it survives a resolution change better than an absolute y.
    static func windowOrigin(screen: CGRect, visibleTop: CGFloat, offset: CGFloat,
                             ringCount: Int) -> CGPoint {
        let size = windowSize(ringCount: ringCount)
        let clamped = clampedOffset(offset, visibleTop: visibleTop, screen: screen,
                                    ringCount: ringCount)
        // AppKit's origin is bottom-left; the dock's top sits `clamped` below `visibleTop`,
        // and the dock is vertically centred in the window.
        let dockTop = visibleTop - clamped
        let dockHeight = self.dockHeight(ringCount: ringCount)
        let dockBottom = dockTop - dockHeight
        let y = dockBottom - (size.height - dockHeight) / 2
        return CGPoint(x: screen.maxX - size.width + bleed, y: y)
    }

    /// How far below the window's top edge the expanded panel starts.
    ///
    /// The window is centred on the dock, and the dock can be dragged to the very top or
    /// the very bottom of the screen — so a panel simply centred in that window hangs off
    /// the screen by up to half its height, which is how the panel's header ended up above
    /// the menu bar. Centre it when there is room, otherwise slide it back inside the
    /// visible area; the dock does not move, so the panel just stops being level with it.
    static func panelTop(windowTop: CGFloat, windowHeight: CGFloat,
                         visibleTop: CGFloat, visibleBottom: CGFloat) -> CGFloat {
        let centred = (windowHeight - panelSize.height) / 2
        // Distances measured downwards from the window's top edge.
        let lowest = windowTop - visibleTop                          // panel top at the ceiling
        let highest = windowTop - visibleBottom - panelSize.height   // panel bottom at the floor
        guard highest > lowest else { return lowest }
        return min(max(centred, lowest), highest)
    }

    /// Keeps the dock fully on screen: never above the menu bar, never past the bottom.
    static func clampedOffset(_ offset: CGFloat, visibleTop: CGFloat, screen: CGRect,
                              ringCount: Int) -> CGFloat {
        let usable = visibleTop - screen.minY
        let maximum = max(0, usable - dockHeight(ringCount: ringCount))
        return max(0, min(offset, maximum))
    }

    /// The offset that centres the dock vertically — where it starts life.
    static func centeredOffset(visibleTop: CGFloat, screen: CGRect, ringCount: Int) -> CGFloat {
        let usable = visibleTop - screen.minY
        return max(0, (usable - dockHeight(ringCount: ringCount)) / 2)
    }

    // MARK: Bubble

    /// Where the bubble sits relative to the dock's top-left corner, and where its tail
    /// meets the ring. The bubble is centred on its ring, then pushed back inside the
    /// window if that would hang it off an edge — the tail stays on the ring regardless,
    /// which is why it is returned separately.
    struct BubblePlacement: Equatable {
        /// Bubble's top edge, measured from the top of the dock (may be negative).
        var top: CGFloat
        /// Tail centre, measured from the bubble's own top edge.
        var tailY: CGFloat
    }

    static func bubblePlacement(ringIndex: Int, ringCount: Int, bubbleHeight: CGFloat,
                                windowHeight: CGFloat, dockTopInWindow: CGFloat)
        -> BubblePlacement {
        let ringY = ringCenterY(index: ringIndex, ringCount: ringCount)
        var top = ringY - bubbleHeight / 2
        // Bubble coordinates are relative to the dock; convert to the window to clamp.
        let minTop = -dockTopInWindow
        let maxTop = windowHeight - dockTopInWindow - bubbleHeight
        top = max(minTop, min(top, maxTop))
        let tailY = min(max(ringY - top, tailHeight / 2), bubbleHeight - tailHeight / 2)
        return BubblePlacement(top: top, tailY: tailY)
    }
}
