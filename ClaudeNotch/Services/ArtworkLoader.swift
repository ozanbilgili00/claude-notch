import AppKit
import CoreImage
import Observation
import SwiftUI

/// Downloads album art and keeps it in memory.
///
/// Written by hand rather than using `AsyncImage` for one specific reason: the artwork
/// participates in the pill → panel morph, and `matchedGeometryEffect` in this project
/// breaks when the tracked view sizes itself from its content (see the comment in
/// `PixelCreature.body`). A plain `Image` in a fixed frame is predictable; an AsyncImage
/// that swaps a placeholder for a photo mid-flight is not.
@MainActor
@Observable
final class ArtworkLoader {

    /// Art for the track currently being shown, or nil while it loads / if it failed.
    private(set) var image: NSImage?

    /// A colour taken from the current cover, safe to draw on the panel's near-black.
    /// Falls back to the app's own accent whenever there is no art.
    private(set) var accent: Color = Theme.accent

    private var cache: [URL: NSImage] = [:]
    private var accents: [URL: Color] = [:]
    private var loadingURL: URL?
    private var task: Task<Void, Never>?

    /// Album covers are a few tens of KB each; a handful of recent ones is plenty and
    /// keeps this from growing without bound over a long-running session.
    private var order: [URL] = []
    private static let limit = 24

    /// Covers for list rows (search results, the queue), kept apart from `image`.
    ///
    /// The single `image`/`accent` pair above is about *the track that is playing* — it
    /// drives the panel's colour and takes part in the pill morph. A list asks a different
    /// question ("give me the art for this row, whenever it turns up") and answering it
    /// through the same property would make the whole panel change colour as a list scrolled.
    private var thumbnails: [URL: NSImage] = [:]
    private var thumbnailTasks: Set<URL> = []

    /// Returns the cover if it is already here, and starts fetching it if it is not.
    /// Views read this every redraw; it must stay cheap and must not re-request.
    func thumbnail(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = thumbnails[url] ?? cache[url] { return cached }
        guard !thumbnailTasks.contains(url) else { return nil }
        thumbnailTasks.insert(url)
        Task { @MainActor [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            defer { self?.thumbnailTasks.remove(url) }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let loaded = NSImage(data: data), let self
            else { return }
            self.thumbnails[url] = loaded
            // Rows are small and there can be a lot of them; drop the oldest half rather
            // than letting a long browsing session hold every cover it ever saw.
            if self.thumbnails.count > 120 {
                for key in self.thumbnails.keys.prefix(60) { self.thumbnails.removeValue(forKey: key) }
            }
        }
        return nil
    }

    func load(_ url: URL?) {
        guard let url else {
            task?.cancel()
            loadingURL = nil
            image = nil
            accent = Theme.accent
            return
        }
        guard url != loadingURL else { return }
        loadingURL = url
        task?.cancel()

        if let cached = cache[url] {
            image = cached
            accent = accents[url] ?? Theme.accent
            return
        }
        image = nil
        accent = Theme.accent
        task = Task { @MainActor [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let loaded = NSImage(data: data),
                  !Task.isCancelled,
                  let self, self.loadingURL == url
            else { return }
            self.store(loaded, for: url)
            self.image = loaded
            self.accent = self.accents[url] ?? Theme.accent
        }
    }

    private func store(_ image: NSImage, for url: URL) {
        cache[url] = image
        accents[url] = Self.accent(from: image)
        order.append(url)
        while order.count > Self.limit {
            let dropped = order.removeFirst()
            cache.removeValue(forKey: dropped)
            accents.removeValue(forKey: dropped)
        }
    }

    /// A colour taken from the cover, pulled into a band that reads on a near-black panel.
    ///
    /// Deliberately *not* the average colour, which is what this used to do. Averaging an
    /// album cover almost always lands on a desaturated brown-grey — light and dark areas
    /// cancel, complementary hues cancel — so nearly every track fell below the saturation
    /// floor and got the app's own green instead of anything from the artwork. The average
    /// is cheap (one GPU reduction) but it answers the wrong question.
    ///
    /// What the eye actually calls "the colour of this cover" is its most *prominent* hue,
    /// so that is what is measured: sample a small grid, throw away the pixels that carry
    /// no colour information, and pick the hue the rest agree on.
    static func accent(from image: NSImage) -> Color {
        guard let pixels = samples(from: image) else { return Theme.accent }
        return dominant(in: pixels) ?? Theme.accent
    }

    /// Grid resolution for the sample. 40×40 = 1600 pixels is far more than enough to find
    /// a dominant hue and costs well under a millisecond, once per track.
    nonisolated private static let grid = 40

    /// Nearest-neighbour on purpose: smooth scaling averages each output pixel from its
    /// neighbours, which is the very blending that flattens the colour out. Sampling keeps
    /// each value exactly as it appears in the artwork.
    nonisolated static func samples(from image: NSImage) -> [UInt8]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let side = grid
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &data, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return data
    }

    /// The most prominent hue in an RGBA buffer, or nil when there isn't one.
    ///
    /// Pure and free of AppKit, which is what makes it testable.
    nonisolated static func dominant(in rgba: [UInt8]) -> Color? {
        let binCount = 24
        var weights = [Double](repeating: 0, count: binCount)
        var hueX = [Double](repeating: 0, count: binCount)
        var hueY = [Double](repeating: 0, count: binCount)
        var saturations = [Double](repeating: 0, count: binCount)
        var brightnesses = [Double](repeating: 0, count: binCount)

        var counted = 0
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            guard rgba[i + 3] > 127 else { continue }
            counted += 1
            let (hue, saturation, brightness) = hsb(Double(rgba[i]) / 255,
                                                    Double(rgba[i + 1]) / 255,
                                                    Double(rgba[i + 2]) / 255)
            // Near-black, near-white and near-grey pixels have a hue, but it is noise:
            // they are the background of half the covers ever printed.
            guard brightness > 0.12, brightness < 0.97, saturation > 0.15 else { continue }

            // Squared saturation: a small patch of vivid colour says more about a cover
            // than a large wash of a barely-tinted one.
            let weight = saturation * saturation * brightness
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            weights[bin] += weight
            // Hue is circular, so it is accumulated as a vector — averaging the raw values
            // would put the mean of red 0.99 and red 0.01 at cyan.
            hueX[bin] += cos(hue * 2 * .pi) * weight
            hueY[bin] += sin(hue * 2 * .pi) * weight
            saturations[bin] += saturation * weight
            brightnesses[bin] += brightness * weight
        }

        guard counted > 0,
              let best = weights.indices.max(by: { weights[$0] < weights[$1] })
        else { return nil }

        // Neighbouring bins are folded in: a hue sitting on a bin boundary would otherwise
        // split its own vote in half and lose to a less prominent colour.
        let group = [(best + binCount - 1) % binCount, best, (best + 1) % binCount]
        let weight = group.reduce(0) { $0 + weights[$1] }
        // A genuinely monochrome cover has no colour to borrow. Inventing one would mean
        // picking a hue at random, so it declines and the caller keeps the app's accent.
        guard weight >= Double(counted) * 0.01 else { return nil }

        let x = group.reduce(0) { $0 + hueX[$1] }
        let y = group.reduce(0) { $0 + hueY[$1] }
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }

        return Color(hue: hue,
                     saturation: clamp(group.reduce(0) { $0 + saturations[$1] } / weight, 0.5, 0.9),
                     brightness: clamp(group.reduce(0) { $0 + brightnesses[$1] } / weight, 0.7, 0.95))
    }

    /// RGB → HSB, with hue in 0..<1.
    nonisolated static func hsb(_ red: Double, _ green: Double, _ blue: Double)
        -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0, maximum > 0 else { return (0, 0, maximum) }

        let hue: Double
        switch maximum {
        case red:   hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default:    hue = (red - green) / delta + 4
        }
        var normalized = hue / 6
        if normalized < 0 { normalized += 1 }
        return (normalized, delta / maximum, maximum)
    }

    nonisolated static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
