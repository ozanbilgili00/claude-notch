import AppKit

/// Describes the physical notch (or a synthesized one on non-notched displays)
/// for the screen we render on.
struct ScreenNotch {
    let screen: NSScreen
    /// Notch size in points. On notched MacBooks this comes from the safe-area inset;
    /// otherwise we synthesize a sensible pill so the app still works on any Mac.
    let notchSize: CGSize
    /// True when the display actually has a hardware notch.
    let isReal: Bool

    static func resolve(for screen: NSScreen) -> ScreenNotch {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0 {
            // auxiliaryTopLeftArea / TopRightArea bracket the notch; width = gap between them.
            let width: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = right.minX - left.maxX
            } else {
                width = 200
            }
            return ScreenNotch(screen: screen,
                               notchSize: CGSize(width: max(width, 180), height: topInset),
                               isReal: true)
        }
        // No hardware notch: synthesize a compact pill hanging from the menu bar.
        return ScreenNotch(screen: screen,
                           notchSize: CGSize(width: 220, height: 32),
                           isReal: false)
    }

    /// Top-center anchor point (screen coordinates, origin bottom-left) of the notch's
    /// horizontal center at the top edge of the screen.
    var topCenterX: CGFloat {
        screen.frame.midX
    }

    var topY: CGFloat {
        screen.frame.maxY
    }
}
