import Foundation

/// The track Spotify is currently on, as read from its scripting interface.
struct SpotifyTrack: Equatable, Identifiable {
    /// Spotify URI, e.g. "spotify:track:2Foc5Q5nqNiosCNqttzHof". Stable per track, so it
    /// doubles as the cache key for lyrics and artwork.
    let id: String
    var name: String
    var artist: String
    var album: String
    /// Spotify reports duration in milliseconds; stored here in seconds to match
    /// `player position` and the timestamps in a lyrics file.
    var duration: TimeInterval
    var artworkURL: URL?
    /// `spotify:track:…` — opening it hands the track back to the Spotify app.
    var spotifyURL: URL?
}

/// One timed line of a synced lyrics file.
struct LyricLine: Equatable, Identifiable {
    /// Index in the parsed file — stable and unique, unlike the timestamp, which can
    /// repeat when several lines share one tag.
    let id: Int
    let time: TimeInterval
    let text: String
}

/// What the lyrics lookup came back with. The distinction matters for what gets drawn:
/// "still looking" is not the same as "this track has no lyrics", and an instrumental is
/// not a failure.
enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    /// Lyrics exist but carry no timestamps, so nothing can be highlighted.
    case plain(String)
    case instrumental
    case unavailable
}
