import SwiftUI
import AppKit

/// The Music tab: a now-playing screen — cover, transport, a scrubbable bar, volume,
/// shuffle/repeat, and lyrics that follow along.
///
/// The whole view is mounted only while the tab is selected, which is what keeps its
/// timeline and the 5-second re-sync from running on a Mac that is just showing sessions.
struct MusicView: View {
    @Bindable var spotify: SpotifyService
    @Bindable var lyrics: LyricsService
    @Bindable var artwork: ArtworkLoader
    @Bindable var web: SpotifyWebAPI

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            player.frame(width: 236)
            MusicSidePanel(spotify: spotify, lyrics: lyrics, artwork: artwork, web: web)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The cover's wash is drawn by `ExpandedView` behind the whole panel, not here:
        // this view starts below the header and tab strip, so filling it stopped the
        // gradient dead on a hard horizontal edge partway down the panel.
        .overlay(alignment: .topTrailing) { trackActions }
        // Ref-counted rather than a plain start/stop: the closed pill can be watching the
        // same service, and whoever leaves last should be the one that stops the re-sync.
        .onAppear {
            spotify.addViewer()
            lyrics.load(for: spotify.track)
            artwork.load(spotify.track?.artworkURL)
        }
        .onDisappear { spotify.removeViewer() }
        .onChange(of: spotify.track) { _, track in
            lyrics.load(for: track)
            artwork.load(track?.artworkURL)
        }
    }

    // MARK: Player column

    @ViewBuilder
    private var player: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            titles
            progress
            transport
            secondaryControls
            Spacer(minLength: 0)
        }
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
            if let image = artwork.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.dim)
            }
        }
        // Fixed square: the art is the one thing here whose intrinsic size would otherwise
        // change the moment the download lands, shifting everything below it.
        .frame(width: 132, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .shadow(color: artwork.accent.opacity(0.28), radius: 14, y: 5)
        .animation(Theme.Motion.value, value: artwork.accent)
    }

    @ViewBuilder
    private var titles: some View {
        if let track = spotify.track {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(Theme.mono(13, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(track.artist)
                    .font(Theme.caption).foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(L(.musicNothingPlaying))
                .font(Theme.caption).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Progress

    /// The bar's *fill* has to be redrawn on a clock — `spotify.position` is computed
    /// rather than stored, so nothing would otherwise tell SwiftUI it changed.
    ///
    /// The gesture, though, deliberately sits OUTSIDE the timeline. Anything inside is
    /// rebuilt four times a second, which tears the tap recogniser down between the mouse
    /// going down and coming back up — clicks on the bar were simply swallowed. Only the
    /// parts that actually animate live under the timeline.
    private var progress: some View {
        let duration = spotify.track?.duration ?? 0
        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHi).frame(height: 4)
                    TimelineView(.animation(minimumInterval: tick)) { _ in
                        let fraction = duration > 0
                            ? min(max(spotify.position / duration, 0), 1) : 0
                        Capsule().fill(artwork.accent)
                            .frame(width: geo.size.width * fraction, height: 4)
                    }
                }
                // Drawn 4pt tall, but a 4pt click target is one the pointer slides past;
                // the hit area is the whole row.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard duration > 0, geo.size.width > 0 else { return }
                    spotify.seek(to: duration * (location.x / geo.size.width))
                }
            }
            .frame(height: 14)

            TimelineView(.animation(minimumInterval: tick)) { _ in
                HStack {
                    Text(Self.clock(spotify.position)).font(Theme.micro).foregroundStyle(Theme.dim)
                    Spacer()
                    Text(Self.clock(duration)).font(Theme.micro).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    /// Effectively "never" when Reduce Motion is on — the numbers still update, just at a
    /// rate that does not count as animation.
    private var tick: Double { Theme.Motion.loopsAllowed ? 0.25 : 60 }

    // MARK: Controls

    private var transport: some View {
        HStack(spacing: 22) {
            transportButton("backward.fill") { spotify.previous() }
            transportButton(spotify.isPlaying ? "pause.fill" : "play.fill", size: 20) {
                spotify.playPause()
            }
            transportButton("forward.fill") { spotify.next() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func transportButton(_ symbol: String, size: CGFloat = 14,
                                 _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.text)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    private var secondaryControls: some View {
        HStack(spacing: 10) {
            toggleButton("shuffle", on: spotify.isShuffling, help: L(.musicShuffle)) {
                spotify.toggleShuffle()
            }
            toggleButton("repeat", on: spotify.isRepeating, help: L(.musicRepeat)) {
                spotify.toggleRepeat()
            }
            Spacer(minLength: 4)
            volume
        }
        .padding(.top, 4)
    }

    private func toggleButton(_ symbol: String, on: Bool, help: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? artwork.accent : Theme.dim)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var volume: some View {
        HStack(spacing: 5) {
            Image(systemName: volumeSymbol)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                // Fixed width so the row doesn't twitch sideways as the glyph changes
                // between the mute / low / high variants while dragging.
                .frame(width: 14, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(spotify.volume) },
                    set: { spotify.previewVolume(Int($0)) }
                ),
                in: 0...100
            ) { editing in
                // One AppleScript round-trip per gesture, not per pixel.
                if !editing { spotify.commitVolume() }
            }
            .controlSize(.mini)
            .tint(artwork.accent)
            .frame(width: 84)
        }
    }

    private var volumeSymbol: String {
        switch spotify.volume {
        case 0: return "speaker.slash.fill"
        case 1..<50: return "speaker.wave.1.fill"
        default: return "speaker.wave.2.fill"
        }
    }

    // MARK: Track actions

    @ViewBuilder
    private var trackActions: some View {
        if spotify.track != nil {
            HStack(spacing: 10) {
                Button { copyTrack() } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? artwork.accent : Theme.dim)
                }
                .buttonStyle(.plain)
                .help(L(.musicCopied))

                Button { spotify.openInSpotify() } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                .help(L(.musicOpenInSpotify))
            }
            .padding(.top, 12)
            .padding(.trailing, 14)
        }
    }

    private func copyTrack() {
        guard let track = spotify.track else { return }
        var lines = ["\(track.artist) — \(track.name)"]
        if let url = track.spotifyURL { lines.append(url.absoluteString) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)

        withAnimation(Theme.Motion.quick) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.Motion.quick) { copied = false }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
