import Foundation
import Observation

/// Fetches timed lyrics from LRCLIB and turns the LRC file into lines the view can walk.
///
/// LRCLIB is the source because it is the only one that can legitimately be used here:
/// it is open, needs no key, and serves synced lyrics. Spotify's own lyrics are licensed
/// from Musixmatch and are not in any public API, so they are off the table regardless of
/// the fact that they are on screen inside Spotify itself.
///
/// Coverage is real but partial — mainstream tracks (including Turkish pop) are usually
/// there, niche catalogue often is not. `LyricsState.unavailable` is a normal outcome,
/// not an error.
@MainActor
@Observable
final class LyricsService {

    private(set) var state: LyricsState = .idle
    /// Which track `state` describes, so a late response for a track the user has already
    /// skipped past can be discarded.
    private var currentTrackID: String?

    private var memoryCache: [String: LyricsState] = [:]
    private var fetchTask: Task<Void, Never>?

    private static let endpoint = "https://lrclib.net/api/get"
    private static let searchEndpoint = "https://lrclib.net/api/search"

    func load(for track: SpotifyTrack?) {
        guard let track else {
            fetchTask?.cancel()
            currentTrackID = nil
            state = .idle
            return
        }
        guard track.id != currentTrackID else { return }
        currentTrackID = track.id
        fetchTask?.cancel()

        if let cached = memoryCache[track.id] ?? Self.readDisk(track.id) {
            memoryCache[track.id] = cached
            state = cached
            return
        }

        state = .loading
        fetchTask = Task { @MainActor [weak self] in
            let result = await Self.fetch(track)
            guard !Task.isCancelled, let self, self.currentTrackID == track.id else { return }
            self.memoryCache[track.id] = result
            Self.writeDisk(track.id, result)
            self.state = result
        }
    }

    // MARK: Fetching

    private struct Payload: Decodable {
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private static func fetch(_ track: SpotifyTrack) async -> LyricsState {
        // The exact-match endpoint wants the duration too, which is what lets LRCLIB pick
        // the right version of a song rather than any recording with the same title.
        var items = [URLQueryItem(name: "artist_name", value: track.artist),
                     URLQueryItem(name: "track_name", value: track.name),
                     URLQueryItem(name: "album_name", value: track.album)]
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        if let payload: Payload = await get(endpoint, items) {
            return interpret(payload)
        }
        // Album or duration mismatches are common; a looser search usually still finds it.
        let searchItems = [URLQueryItem(name: "artist_name", value: track.artist),
                           URLQueryItem(name: "track_name", value: track.name)]
        if let results: [Payload] = await get(searchEndpoint, searchItems) {
            if let synced = results.first(where: { $0.syncedLyrics?.isEmpty == false }) {
                return interpret(synced)
            }
            if let first = results.first { return interpret(first) }
        }
        return .unavailable
    }

    private static func get<T: Decodable>(_ base: String, _ items: [URLQueryItem]) async -> T? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // LRCLIB asks clients to identify themselves.
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return decoded
    }

    private static func interpret(_ payload: Payload) -> LyricsState {
        if payload.instrumental == true { return .instrumental }
        if let synced = payload.syncedLyrics, !synced.isEmpty {
            let lines = LRC.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = payload.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return .unavailable
    }

    // MARK: Disk cache

    /// Lyrics for a track never change, so a hit here saves a round-trip every time the
    /// same song comes round again.
    private static func cacheDir() -> URL {
        let dir = UnixSocket.appSupportDir().appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(_ trackID: String) -> URL {
        // Track ids are Spotify URIs with colons in them; not a legal filename.
        let safe = trackID.replacingOccurrences(of: ":", with: "_")
        return cacheDir().appendingPathComponent("\(safe).lrc")
    }

    private static func readDisk(_ trackID: String) -> LyricsState? {
        guard let text = try? String(contentsOf: cacheURL(trackID), encoding: .utf8) else { return nil }
        if text == instrumentalMarker { return .instrumental }
        if text == unavailableMarker { return .unavailable }
        let lines = LRC.parse(text)
        return lines.isEmpty ? .plain(text) : .synced(lines)
    }

    private static let instrumentalMarker = "\u{1}instrumental"
    private static let unavailableMarker = "\u{1}unavailable"

    private static func writeDisk(_ trackID: String, _ state: LyricsState) {
        let body: String
        switch state {
        case .synced(let lines):
            body = lines.map { LRC.format(time: $0.time) + $0.text }.joined(separator: "\n")
        case .plain(let text):     body = text
        case .instrumental:        body = instrumentalMarker
        case .unavailable:         body = unavailableMarker
        case .idle, .loading:      return
        }
        try? body.write(to: cacheURL(trackID), atomically: true, encoding: .utf8)
    }
}

/// LRC parsing, kept as pure functions so the timestamp handling can be tested without a
/// network or a running Spotify.
enum LRC {

    /// Parses an LRC file into timed lines, sorted by time.
    ///
    /// Handles the shapes that actually turn up in the wild: two- or three-digit
    /// fractions (`[01:23.45]` and `[01:23.456]`), several timestamps on one line for a
    /// repeated chorus, and metadata tags (`[ar:…]`, `[offset:…]`) that carry no time and
    /// must not become lyrics.
    static func parse(_ source: String) -> [LyricLine] {
        var out: [(TimeInterval, String)] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            var times: [TimeInterval] = []
            var index = line.startIndex

            // Timestamps only count while they run consecutively from the start; a "["
            // later in the line is part of the lyric.
            while index < line.endIndex, line[index] == "[" {
                guard let close = line[index...].firstIndex(of: "]") else { break }
                let body = String(line[line.index(after: index)..<close])
                guard let time = parseTimestamp(body) else { break }
                times.append(time)
                index = line.index(after: close)
            }
            guard !times.isEmpty else { continue }

            let text = String(line[index...]).trimmingCharacters(in: .whitespaces)
            for time in times { out.append((time, text)) }
        }
        return out.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// "01:23.45" → 83.45. Returns nil for metadata tags like "ar:Daft Punk".
    static func parseTimestamp(_ body: String) -> TimeInterval? {
        let parts = body.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              minutes >= 0
        else { return nil }
        let secondsPart = parts[1].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart), seconds >= 0 else { return nil }
        return TimeInterval(minutes) * 60 + seconds
    }

    static func format(time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "[%02d:%05.2f]", minutes, seconds)
    }

    /// Index of the line that should be highlighted at `position`, or nil before the
    /// first one. The last line at or before the position wins, which is what makes
    /// repeated timestamps and zero-length lines behave.
    static func activeIndex(_ lines: [LyricLine], at position: TimeInterval) -> Int? {
        guard let first = lines.first, position >= first.time else { return nil }
        var low = 0, high = lines.count - 1, answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }
}
