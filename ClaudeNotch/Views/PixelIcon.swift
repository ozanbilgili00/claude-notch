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
struct WorkingBars: View {
    var color: Color
    @State private var phase: CGFloat = 0
    private let heights: [CGFloat] = [0.4, 1.0, 0.6, 0.9, 0.5]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<heights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color)
                    .frame(width: 2, height: 10 * animatedHeight(i))
            }
        }
        .frame(height: 12, alignment: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func animatedHeight(_ i: Int) -> CGFloat {
        let base = heights[i]
        // Offset each bar so they don't move in unison.
        let wobble = 0.4 * sin((phase * .pi * 2) + CGFloat(i))
        return max(0.2, min(1.0, base + wobble * phase))
    }
}
