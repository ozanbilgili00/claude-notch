import SwiftUI

/// The right-hand column of the Music tab: a search field over one of three things —
/// lyrics, the queue, or search results.
///
/// Search deliberately *replaces* the column rather than opening somewhere else. The
/// panel is 720pt wide and already carries a player; a results list that pushed the
/// lyrics aside would leave neither with room to be read.
struct MusicSidePanel: View {
    @Bindable var spotify: SpotifyService
    @Bindable var lyrics: LyricsService
    @Bindable var artwork: ArtworkLoader
    @Bindable var web: SpotifyWebAPI
    @AppStorage("showLyrics") private var showLyrics = true

    enum Mode { case lyrics, queue }
    @State private var mode: Mode = .lyrics

    @State private var query = ""
    @State private var results: [SpotifyTrack] = []
    @State private var searching = false
    /// Query → results, so backspacing through a word doesn't re-ask the network for
    /// prefixes it already has.
    @State private var cache: [String: [SpotifyTrack]] = [:]
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            header
            content
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            searchField
            if query.isEmpty && showLyrics {
                segment(L(.tabLyrics), .lyrics)
                segment(L(.tabQueue), .queue)
            }
        }
        // Room for the copy / open-in-Spotify pair, which floats in the panel's top-right
        // corner. Without this the queue button renders underneath them.
        .padding(.trailing, 48)
    }

    /// Same shape as the log viewer's filter field, so the panel has one search idiom.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
            TextField(L(.musicSearchPlaceholder), text: $query)
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(Theme.text)
            if !query.isEmpty {
                Button { clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
        )
        .onChange(of: query) { _, text in scheduleSearch(text) }
    }

    private func segment(_ title: String, _ value: Mode) -> some View {
        Button { withAnimation(Theme.Motion.quick) { mode = value } } label: {
            Text(title)
                .font(Theme.micro)
                .foregroundStyle(mode == value ? Theme.text : Theme.dim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(mode == value ? Theme.surfaceHi : .clear)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !query.isEmpty {
            searchResults
        } else if mode == .queue {
            QueueView(spotify: spotify, artwork: artwork, web: web)
        } else if showLyrics {
            LyricsPane(state: lyrics.state,
                       position: { spotify.position },
                       accent: artwork.accent,
                       onSeek: { spotify.seek(to: $0) })
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if web.state != .connected {
            notice(L(.queueSignInNeeded))
        } else if results.isEmpty {
            notice(searching ? L(.musicSearching) : L(.musicNoResults))
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(results) { track in
                        TrackResultRow(artwork: artwork, track: track) { play(track) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Search

    /// Typed characters arrive faster than the network can answer them, so each keystroke
    /// cancels the one before it and waits out a short pause. Without this every letter is
    /// its own request, Spotify rate-limits the burst, and replies that land out of order
    /// make the list flicker between two different searches.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; searching = false; return }

        let key = trimmed.lowercased()
        if let cached = cache[key] { results = cached; searching = false; return }

        searching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await web.search(trimmed)
            guard !Task.isCancelled else { return }
            cache[key] = found
            results = found
            searching = false
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        searching = false
    }

    /// Playing goes through the local app, not the Web API: `play track` needs no extra
    /// scope and works on a free account, while the Web API's playback endpoints require
    /// Premium.
    private func play(_ track: SpotifyTrack) {
        spotify.play(uri: track.id)
        clearSearch()
    }
}
