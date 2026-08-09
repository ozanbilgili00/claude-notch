import SwiftUI

/// Tiny pixel-art glyphs rendered from bitmaps: an N-row string array where `#` is a
/// filled pixel and `+` an optional lighter tone. The session creatures come from real
/// artwork in `Assets.xcassets` (see `PixelCreature`); these glyphs are the small
/// decorative markers — the empty state and the equalizer.
struct PixelIcon: View {
    let pattern: [String]
    var color: Color
    /// Tone for `+` pixels. Defaults to a lighter wash of `color`.
    var highlight: Color?
    var pixel: CGFloat = 2.0
    var spacing: CGFloat = 0.5

    var body: some View {
        Canvas { ctx, _ in
            let light = highlight ?? color.opacity(0.55)
            for (row, line) in pattern.enumerated() {
                for (col, ch) in line.enumerated() where ch == "#" || ch == "+" {
                    let rect = CGRect(
                        x: CGFloat(col) * (pixel + spacing),
                        y: CGFloat(row) * (pixel + spacing),
                        width: pixel, height: pixel
                    )
                    ctx.fill(Path(rect), with: .color(ch == "#" ? color : light))
                }
            }
        }
        .frame(width: CGFloat(pattern.map(\.count).max() ?? 0) * (pixel + spacing),
               height: CGFloat(pattern.count) * (pixel + spacing))
    }

    // MARK: Glyph library

    static let invader: [String] = [
        "..#.....#..",
        "...#...#...",
        "..#######..",
        ".##.###.##.",
        "###########",
        "#.#######.#",
        "#.#.....#.#",
        "...##.##...",
    ]

    static let crab: [String] = [
        "#...#",
        ".###.",
        "##.##",
        "#####",
        "#.#.#",
        "..#..",
    ]

    static let bars: [String] = [   // little equalizer / working bars
        "#...#",
        "#.#.#",
        "#.#.#",
        "#.#.#",
        "#####",
    ]
}

/// An animated equalizer glyph used to signal "working".
///
/// The tempo follows what Claude is actually doing, so the bars carry information
/// instead of just being decoration: a shell command drums, planning idles.
struct WorkingBars: View {
    var color: Color
    var activity: ActivityKind = .shell

    private static let heights: [CGFloat] = [0.4, 1.0, 0.6, 0.9, 0.5]

    private var period: Double {
        switch activity {
        case .running, .shell:      return 0.55
        case .searching, .reading:  return 0.75
        case .editing:              return 0.9
        case .planning:             return 1.7
        case .waiting, .idle:       return 2.2
        }
    }

    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 1.5
    private static var totalWidth: CGFloat {
        CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * barGap
    }

    var body: some View {
        // Drawn in a Canvas, not as a stack of resizing rectangles. Changing a view's
        // frame every tick makes SwiftUI re-run layout for the whole row — with one of
        // these per session that alone cost ~12% CPU. A Canvas only ever draws.
        //
        // Driven by a timeline rather than a repeating animation so the frame rate is
        // ours to cap; 20 fps is plenty for five 2pt bars.
        if Theme.Motion.loopsAllowed {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                bars(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(at: 0)
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        Canvas { ctx, size in
            for i in 0..<Self.heights.count {
                let h = 10 * height(i, at: time)
                let x = CGFloat(i) * (Self.barWidth + Self.barGap)
                let rect = CGRect(x: x, y: size.height - h, width: Self.barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(color))
            }
        }
        .frame(width: Self.totalWidth, height: 12)
    }

    private func height(_ i: Int, at time: TimeInterval) -> CGFloat {
        // Offset each bar so they don't move in unison.
        let phase = (time / period) * 2 * .pi + Double(i) * 0.9
        let wobble = 0.42 * sin(phase)
        return max(0.18, min(1.0, Self.heights[i] + wobble))
    }
}
