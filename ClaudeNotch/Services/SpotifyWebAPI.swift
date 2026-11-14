import AppKit
import Observation

/// The Spotify Web API: search, the play queue, and recently played.
///
/// Separate from `SpotifyService` on purpose. That one talks to the *local* Spotify app
/// over AppleScript and costs nothing when Spotify is closed; this one talks to Spotify's
/// servers, needs an account, and only runs when a view actually asks it something. Keeping
/// them apart means the notch still works exactly as before for anyone who never signs in.
@MainActor
@Observable
final class SpotifyWebAPI {

    enum State: Equatable {
        case needsSetup          // no Client ID entered yet
        case signedOut
        case connecting
        case connected
        case expired             // refresh failed; the user has to sign in again
    }

    private(set) var state: State = .signedOut

    /// The user's own Client ID from developer.spotify.com. Public by design, so it lives
    /// in UserDefaults rather than the Keychain.
    var clientID: String {
        didSet {
            guard clientID != oldValue else { return }
            UserDefaults.standard.set(clientID, forKey: "spotifyClientID")
            state = clientID.isEmpty ? .needsSetup
                : (SpotifyKeychain.readRefreshToken() != nil ? .connected : .signedOut)
        }
    }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    init() {
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        if clientID.isEmpty {
            state = .needsSetup
        } else {
            state = SpotifyKeychain.readRefreshToken() != nil ? .connected : .signedOut
        }
    }

    // MARK: Sign in / out

    func connect(anchor: NSWindow?) async {
        guard !clientID.isEmpty else { state = .needsSetup; return }
        state = .connecting
        let verifier = SpotifyAuth.PKCE.makeVerifier()
        do {
            let code = try await SpotifyAuth.authorize(clientID: clientID,
                                                       verifier: verifier, anchor: anchor)
            let tokens = try await SpotifyAuth.exchange(code: code, verifier: verifier,
                                                        clientID: clientID)
            apply(tokens)
            state = .connected
        } catch {
            debug("connect failed: \(error)")
            state = SpotifyKeychain.readRefreshToken() != nil ? .connected : .signedOut
        }
    }

    func disconnect() {
        SpotifyKeychain.clear()
        accessToken = nil
        accessTokenExpiry = .distantPast
        state = clientID.isEmpty ? .needsSetup : .signedOut
    }

    private func apply(_ tokens: SpotifyAuth.Tokens) {
        accessToken = tokens.access_token
        // 30 seconds of slack so a request never leaves with a token that expires in flight.
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expires_in) - 30)
        // Spotify rotates the refresh token on every renewal under PKCE. Dropping the new
        // one leaves the old value in the Keychain, which stops working within the hour —
        // the sign-in appears to die on its own a while after it succeeded.
        if let refresh = tokens.refresh_token { SpotifyKeychain.write(refreshToken: refresh) }
    }

    // MARK: Requests

    /// A valid access token, renewing it first if the current one is stale.
    private func validToken() async -> String? {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = SpotifyKeychain.readRefreshToken(), !clientID.isEmpty else {
            return nil
        }
        do {
            apply(try await SpotifyAuth.refresh(refresh, clientID: clientID))
            state = .connected
            return accessToken
        } catch {
            debug("refresh failed: \(error)")
            state = .expired
            return nil
        }
    }

    /// One GET, retried once after a forced renewal.
    ///
    /// The retry exists because a token can be revoked server-side (password change, app
    /// removed from the account) while our clock still believes it is valid — the only
    /// signal is the 401 itself.
    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async -> T? {
        guard var components = URLComponents(string: "https://api.spotify.com/v1" + path)
        else { return nil }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { return nil }

        for attempt in 0..<2 {
            if attempt == 1 { accessTokenExpiry = .distantPast }
            guard let token = await validToken() else { return nil }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 12

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return nil }

            switch http.statusCode {
            case 200:
                return try? JSONDecoder().decode(T.self, from: data)
            case 204:
                // "Nothing is playing" — a legitimate answer, not a failure.
                return nil
            case 401:
                continue
            default:
                debug("GET \(path) → \(http.statusCode) \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
        }
        return nil
    }

    // MARK: Endpoints

    /// Ten, not the API's documented maximum of fifty.
    ///
    /// A Spotify app in development mode — which is what anyone gets without applying for
    /// an extension quota — rejects anything above 10 with a flat 400 "Invalid limit".
    /// Measured against this account: 5 and 10 pass, 15 and 50 do not. Ten rows is also
    /// about what the panel can show without scrolling, so this costs nothing on screen.
    func search(_ query: String, limit: Int = 10) async -> [SpotifyTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let page: Payload.SearchResponse? = await get("/search", [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return page?.tracks.items.compactMap(\.track) ?? []
    }

    func queue() async -> [SpotifyTrack] {
        let response: Payload.QueueResponse? = await get("/me/player/queue")
        return response?.queue.compactMap(\.track) ?? []
    }

    /// Same development-mode ceiling as `search`.
    func recentlyPlayed(limit: Int = 10) async -> [SpotifyTrack] {
        let response: Payload.RecentResponse? = await get("/me/player/recently-played", [
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return response?.items.compactMap { $0.track.track } ?? []
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" else { return }
        fputs("[spotify-web] \(message)\n", stderr)
    }
}

/// Wire format. Deliberately minimal — only the fields that end up on screen, so a change
/// elsewhere in Spotify's response can't break decoding.
enum Payload {
    struct Item: Decodable {
        var id: String?
        var uri: String?
        var name: String?
        var duration_ms: Int?
        var artists: [Artist]?
        var album: Album?

        /// nil for anything that isn't a playable track (podcast episodes come through the
        /// same list and carry none of these fields).
        var track: SpotifyTrack? {
            guard let id, let name else { return nil }
            return SpotifyTrack(
                id: uri ?? id,
                name: name,
                artist: artists?.compactMap(\.name).joined(separator: ", ") ?? "",
                album: album?.name ?? "",
                duration: Double(duration_ms ?? 0) / 1000,
                artworkURL: album?.images?.first.flatMap { URL(string: $0.url) },
                spotifyURL: uri.flatMap { URL(string: $0) }
            )
        }
    }

    struct Artist: Decodable { var name: String? }
    struct Album: Decodable {
        var name: String?
        var images: [Image]?
    }
    struct Image: Decodable { var url: String }

    struct SearchResponse: Decodable {
        struct Tracks: Decodable { var items: [Item] }
        var tracks: Tracks
    }
    struct QueueResponse: Decodable {
        var currently_playing: Item?
        var queue: [Item]
    }
    struct RecentResponse: Decodable {
        struct Entry: Decodable { var track: Item }
        var items: [Entry]
    }
}
