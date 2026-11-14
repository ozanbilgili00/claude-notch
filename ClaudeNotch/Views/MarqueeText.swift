import SwiftUI

/// One line of text that slides sideways when it is too long for the space it is given,
/// and sits perfectly still when it isn't.
///
/// That condition is the whole point. This runs in the menu bar, on every Space, for as
/// long as music is playing — a permanently scrolling label would be the most distracting
/// thing on the screen. Short titles get no animation at all, and Reduce Motion turns the
/// scrolling off entirely (the text is then simply truncated).
struct MarqueeText: View {
    let text: String
    var font: Font
    /// The width available. Fixed rather than measured from a GeometryReader: the pill's
    /// own width depends on its contents, so measuring here would feed size back into the
    /// layout that produced it.
    var width: CGFloat
    var speed: Double = 22          // points per second
    var gap: CGFloat = 28           // blank run between the end and the repeat

    @State private var textWidth: CGFloat = 0

    private var overflows: Bool { textWidth > width && Theme.Motion.loopsAllowed }

    var body: some View {
        Group {
            if overflows {
                scrolling
            } else {
                Text(text).font(font).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        .background(measurer)
        .animation(nil, value: text)   // a title change should cut, not slide
    }

    /// Draws the text off-screen once to learn its natural width. `hidden()` keeps it out
    /// of the render pass while still giving it a real layout.
    private var measurer: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { textWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, new in textWidth = new }
                }
            )
    }

    /// Two copies chasing each other, offset by a clock rather than by a repeating
    /// animation so the phase is derived from the time and never drifts or restarts.
    private var scrolling: some View {
        let cycle = textWidth + gap
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let offset = -CGFloat((elapsed * speed).truncatingRemainder(dividingBy: Double(cycle)))
            HStack(spacing: gap) {
                Text(text).font(font).lineLimit(1).fixedSize()
                Text(text).font(font).lineLimit(1).fixedSize()
            }
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
        }
    }
}
