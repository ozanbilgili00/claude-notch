import SwiftUI

/// Timed lyrics, presented the way a now-playing screen presents them: the current line
/// carries the weight, the lines around it recede, and clicking any line jumps there.
struct LyricsPane: View {
    let state: LyricsState
    /// Read rather than passed: a plain value would be frozen at the moment the parent
    /// last redrew, and the parent deliberately does not redraw on a clock.
    var position: () -> TimeInterval
    var accent: Color
    var onSeek: (TimeInterval) -> Void

    /// The active line index, written by the timeline below and read by the list.
    ///
    /// Split deliberately: a tap recogniser inside a `TimelineView` is torn down between
    /// the mouse going down and coming back up, so clicks on the lines were swallowed —
    /// the same failure the progress bar hit. Only the *index* is computed on the clock;
    /// the rows that carry the gestures live outside it and just read this.
    @State private var active: Int?

    var body: some View {
        switch state {
        case .synced(let lines):
            synced(lines)
        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(Theme.caption).foregroundStyle(Theme.textDim)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            .mask(edgeFade)
        case .loading:
            notice(L(.musicLyricsLoading))
        case .instrumental:
            notice(L(.musicInstrumental))
        case .unavailable:
            notice(L(.musicNoLyrics))
        case .idle:
            notice(L(.musicNothingPlaying))
        }
    }

    // MARK: Synced

    private func synced(_ lines: [LyricLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { line in
                        row(line, distance: distance(of: line.id))
                            .id(line.id)
                    }
                }
                // Asymmetric on purpose. The bottom keeps half a pane of slack so the
                // closing lines can still be scrolled up into focus, but the top gets
                // almost none: padding there is dead space at the start of every track,
                // when the active line is near the beginning and the list has nothing to
                // scroll — the lyrics just sat in the middle of the pane with a gap above.
                // Just enough to clear the top fade below, so the very first line of a
                // track — which has nothing above it to scroll under — is drawn at full
                // strength instead of half-dissolved.
                .padding(.top, 10)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.never)
            .mask(edgeFade)
            .background(clock)
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(Theme.Motion.quick) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ line: LyricLine, distance: Int) -> some View {
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(distance == 0 ? Theme.mono(14, .semibold) : Theme.caption)
            .foregroundStyle(tint(for: distance))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { onSeek(line.time) }
            .animation(Theme.Motion.quick, value: distance == 0)
    }

    private func tint(for distance: Int) -> Color {
        switch distance {
        case 0: return accent
        case 1: return Theme.textDim
        default: return Theme.dim.opacity(0.7)
        }
    }

    private func distance(of id: Int) -> Int {
        guard let active else { return 2 }
        return abs(id - active)
    }

    /// The only part that runs on a clock. 5 fps is ample for text that changes every few
    /// seconds, and it costs a fraction of an animation-rate timeline.
    private var clock: some View {
        TimelineView(.animation(minimumInterval: Theme.Motion.loopsAllowed ? 0.2 : 60)) { _ in
            let index = currentIndex()
            Color.clear
                .onChange(of: index, initial: true) { _, new in active = new }
        }
    }

    private func currentIndex() -> Int? {
        guard case .synced(let lines) = state else { return nil }
        return LRC.activeIndex(lines, at: position())
    }

    // MARK: Chrome

    /// Apple's now-playing lyrics fade at the top and bottom rather than ending on a hard
    /// edge; the mask is what stops the scroll looking like a clipped text box.
    ///
    /// The top fade is much shorter than the bottom one: with the list now starting flush
    /// against the top, a long fade there would swallow the first line of every song.
    private var edgeFade: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0),
                    .init(color: .black, location: 0.03),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
