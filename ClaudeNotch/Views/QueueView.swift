import SwiftUI

/// What played before, what is playing, what is next — one list, in that order.
///
/// The two halves come from different places and have different guarantees: recently
/// played is a plain history endpoint that works on any account, while the queue is part
/// of Spotify's player API and can come back empty (nothing queued, or radio deciding as
/// it goes). The view is built so the "next" half being missing costs nothing.
struct QueueView: View {
    @Bindable var spotify: SpotifyService
    @Bindable var artwork: ArtworkLoader
    @Bindable var web: SpotifyWebAPI

    @State private var previous: [SpotifyTrack] = []
    @State private var next: [SpotifyTrack] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if web.state != .connected {
                notice(L(.queueSignInNeeded))
            } else if loaded && previous.isEmpty && next.isEmpty {
                notice(L(.queueEmpty))
            } else {
                list
            }
        }
        .task { await reload() }
        // The queue is only fetched while this view is on screen and when the track
        // changes — the same discipline the rest of the app follows: nothing spins when
        // no one is looking.
        .onChange(of: spotify.track?.id) { _, _ in Task { await reload() } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !previous.isEmpty {
                    section(L(.queuePrevious))
                    // Reversed so the most recent sits closest to "now" — read downwards,
                    // the list runs forwards in time.
                    ForEach(previous.reversed()) { row($0) }
                }
                if let current = spotify.track {
                    section(L(.queueNow))
                    TrackResultRow(artwork: artwork, track: current, isCurrent: true) {}
                }
                if !next.isEmpty {
                    section(L(.queueNext))
                    ForEach(next) { row($0) }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    private func row(_ track: SpotifyTrack) -> some View {
        TrackResultRow(artwork: artwork, track: track) { spotify.play(uri: track.id) }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(Theme.micro).foregroundStyle(Theme.dim)
            .padding(.horizontal, 8)
            .padding(.top, 8).padding(.bottom, 2)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        guard web.state == .connected else { return }
        // Both are read even though only one may work; whichever answers gets shown.
        previous = await web.recentlyPlayed(limit: 8)
        next = await web.queue()
        loaded = true
    }
}
