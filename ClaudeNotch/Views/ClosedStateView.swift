import SwiftUI

/// Identifiers for the elements that exist in both the closed pill and the expanded
/// panel. They are matched across the morph so they fly between layouts instead of
/// cross-fading in place — the difference between "the notch grew" and "two views swapped".
enum MorphID {
    static let creature = "morph.creature"
    static let status   = "morph.status"
    static let usage    = "morph.usage"
    static let count    = "morph.count"
}

/// The compact pill shown when the notch is closed: the mascot and status on the left of
/// the physical notch, a mini usage readout on the right.
struct ClosedStateView: View {
    @Bindable var store: SessionStore
    @Bindable var spotify: SpotifyService
    @Bindable var artwork: ArtworkLoader
    @AppStorage("showTrackInPill") private var showTrackInPill = true
    /// Whether this Mac actually has a physical camera notch, vs. the synthesized pill
    /// drawn on external displays. Only the real one visually crowds the mascot.
    var isRealNotch: Bool
    var notchWidth: CGFloat
    var ns: Namespace.ID
    /// True while the pill is the visible state; the expanded panel takes over as the
    /// geometry source once it is on screen.
    var isSource: Bool = true

    private var focused: Session? { store.focusedSession }

    var body: some View {
        HStack(spacing: 0) {
            leftCluster
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            // Gap that sits under the physical camera notch (matches its real width).
            Color.clear.frame(width: notchWidth)

            rightCluster
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(Theme.text)
    }

    /// On the real notch, working already shows the equalizer bars right next to the
    /// mascot in a strip barely wider than the camera housing itself — crowded enough
    /// that the turtle reads as a smudge rather than a mascot. Dropping it while working
    /// leaves the bars as the sole activity indicator there. The synthesized pill on an
    /// external display has the room to keep it, so this only applies to the real one.
    /// Also hidden while a track is showing: the album art takes the mascot's place as
    /// the left-hand icon, and the pill has nowhere near enough width for both plus a
    /// title — squeezing all three crushed the usage readout on the other side.
    /// And hidden again while something needs the user: the bell is already the icon for
    /// that state, so the mascot only pushes it and its label further from the edge.
    private var hidesCreatureWhileWorking: Bool {
        (isRealNotch && store.aggregateStatus == .working) || showsTrack || needsUser
    }

    private var leftCluster: some View {
        HStack(spacing: 6) {
            // The turtle is the notch's own mascot (sessions get Claude's critter).
            //
            // Collapsed to zero width rather than removed with `if`: matchedGeometryEffect
            // pairs this instance with the one in the expanded header by id, and pulling a
            // participant out of the tree — instead of just shrinking it — left that pairing
            // with no source to hand off from, which made the expanded header's creature
            // render at zero size too, even though nothing there asked it to.
            PixelCreature(art: .turtle,
                          tint: store.aggregateStatus.creatureTint,
                          height: 18,
                          motion: .forStatus(store.aggregateStatus,
                                             activity: focused?.activity ?? .idle),
                          pace: PixelCreature.pace(for: focused?.activity ?? .idle,
                                                   working: store.workingCount),
                          event: store.event,
                          activity: focused?.activity ?? .idle)
                .matchedGeometryEffect(id: MorphID.creature, in: ns, isSource: isSource)
                .frame(width: hidesCreatureWhileWorking ? 0 : nil)
                .opacity(hidesCreatureWhileWorking ? 0 : 1)
                .clipped()
                // The view stays in the tree for matchedGeometryEffect's sake, but an
                // HStack still lays out its spacing after a zero-width child — cancelled
                // here so whatever follows really does sit against the left edge.
                .padding(.trailing, hidesCreatureWhileWorking ? -6 : 0)
            statusGlyph
            if showsTrack, let track = spotify.track {
                nowPlaying(track)
            } else {
                Text(store.statusWord)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .fixedSize()
                    .matchedGeometryEffect(id: MorphID.status, in: ns, isSource: isSource)
            }
        }
    }

    /// The one moving thing in the pill, and the only slot that survives a track title
    /// taking over the rest of the strip.
    ///
    /// Working shows the equalizer; anything that *needs* the user gets a symbol instead,
    /// because the sound that used to announce it is the first thing music drowns out —
    /// which is exactly how a question goes unanswered for ten minutes. Amber bell for a
    /// question or a permission, red exclamation for a failure, matching the colours the
    /// rest of the app already uses for those two states.
    @ViewBuilder
    private var statusGlyph: some View {
        switch store.aggregateStatus {
        case .working:
            WorkingBars(color: Theme.green, activity: focused?.activity ?? .shell)
        case .waiting:
            alertSymbol("bell.fill", Theme.amber)
        case .error:
            alertSymbol("exclamationmark.circle.fill", Theme.red)
        case .idle:
            EmptyView()
        }
    }

    private func alertSymbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            // A slow pulse rather than a static icon: this is the notch's way of raising
            // its hand, and a still glyph in a strip the eye has learned to ignore is
            // easy to miss. Suppressed entirely under Reduce Motion, like every other
            // loop in the app.
            .symbolEffect(.pulse, options: .repeating, isActive: Theme.Motion.loopsAllowed)
    }

    /// True whenever the slot above is occupied — the title has that much less room.
    private var hasStatusGlyph: Bool { store.aggregateStatus != .idle }

    /// The track replaces the status word only while nothing needs the user. A pending
    /// permission is the whole reason this app exists; music must never sit on top of it.
    private var showsTrack: Bool {
        showTrackInPill && spotify.enabled && spotify.isPlaying && !needsUser
    }

    /// Keyed on the status rather than on `blockingSession`: a notification-driven "waiting"
    /// has no permission or question object attached to it, so testing for one let the
    /// track title sit on top of the very state the user is being asked to notice.
    private var needsUser: Bool {
        store.aggregateStatus == .waiting || store.aggregateStatus == .error
    }

    private func nowPlaying(_ track: SpotifyTrack) -> some View {
        HStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.surfaceHi)
                if let image = artwork.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            // Fixed square for the same reason the creature is: art that sizes itself
            // from a download that lands mid-morph breaks matchedGeometryEffect here.
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            MarqueeText(text: "\(track.name) — \(track.artist)",
                        font: Theme.caption, width: marqueeWidth)
                .foregroundStyle(Theme.textDim)
        }
        .onAppear { artwork.load(track.artworkURL) }
        .onChange(of: track.artworkURL) { _, url in artwork.load(url) }
    }

    /// The pill's width is fixed (`notchWidth + 230`), so the title is the one element
    /// that has to give: with the equalizer bars also on the left there is no longer room
    /// for a full-width marquee, and the overflow lands on the usage readout across the
    /// gap rather than on the title itself.
    private var marqueeWidth: CGFloat {
        hasStatusGlyph ? 62 : 86
    }

    private var rightCluster: some View {
        HStack(spacing: 6) {
            if store.usage.isLive {
                HStack(spacing: 4) {
                    Text(L(.usageFiveHour)).font(Theme.micro).foregroundStyle(Theme.dim)
                    Text(L10n.percent(Int(store.usage.fiveHourPercent * 100),
                                      Localization.shared.language))
                        .font(Theme.micro)
                        .foregroundStyle(store.usage.fiveHourPercent > 0.85 ? Theme.red
                                         : store.usage.fiveHourPercent > 0.6 ? Theme.amber : Theme.green)
                        .contentTransition(.numericText(value: store.usage.fiveHourPercent))
                }
                // Same guard the session count already carries. Without it the readout is
                // the first thing the layout squeezes when the left half grows, and a
                // percentage that has wrapped onto two lines reads as a different number.
                .lineLimit(1).fixedSize()
                .animation(Theme.Motion.value, value: store.usage.fiveHourPercent)
                .matchedGeometryEffect(id: MorphID.usage, in: ns, isSource: isSource)
            }
            let n = store.sessions.count
            Text(L(.sessionCountShort, n))
                .font(Theme.micro).foregroundStyle(Theme.dim)
                // Without this it wraps to two lines as soon as the left half grows —
                // which it does the moment a track title appears there.
                .lineLimit(1).fixedSize()
                .contentTransition(.numericText(value: Double(n)))
                .animation(Theme.Motion.value, value: n)
                .matchedGeometryEffect(id: MorphID.count, in: ns, isSource: isSource)
        }
    }

}
