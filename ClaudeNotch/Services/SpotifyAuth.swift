import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Spotify Web API sign-in: Authorization Code with PKCE.
///
/// PKCE rather than the classic authorization-code flow because it needs **no client
/// secret** — there is no secret to embed in a shipped app, and none to leak. The user
/// registers a free app on developer.spotify.com and pastes only its Client ID, which is
/// public information by design.
///
/// The scopes are deliberately narrow: reading the queue and the recently-played list.
/// Playback is driven through AppleScript's `play track`, so the app never asks for
/// `user-modify-playback-state` — which also sidesteps the Premium requirement that
/// Spotify puts on the Web API's playback-control endpoints.
enum SpotifyAuth {

    /// Registered in the user's Spotify app settings. `ASWebAuthenticationSession`
    /// intercepts this itself, so the scheme does **not** need a `CFBundleURLTypes` entry
    /// — which matters here, because an array-valued Info.plist key cannot be expressed
    /// as an `INFOPLIST_KEY_*` build setting and hand-editing the pbxproj has broken this
    /// project before.
    static let redirectURI = "claudenotch://spotify-login-callback"
    static let callbackScheme = "claudenotch"
    static let scopes = ["user-read-playback-state", "user-read-recently-played"]

    // MARK: PKCE

    /// The two halves of a PKCE challenge. Pure, so the encoding can be tested without
    /// touching the network.
    enum PKCE {
        /// Spotify requires 43–128 characters; 64 random bytes encode to 86.
        static func makeVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 64)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return base64URL(Data(bytes))
        }

        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        /// base64url, unpadded — plain base64 would put `+`, `/` and `=` into a query
        /// string, and the server compares the challenge byte for byte.
        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    /// The URL the browser is sent to. Pure, so the query can be asserted in tests.
    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    /// Pulls the authorization code out of the callback, rejecting a reply whose `state`
    /// doesn't match the one we sent.
    static func code(from callback: URL, expectedState: String) -> String? {
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == expectedState
        else { return nil }
        return items.first(where: { $0.name == "code" })?.value
    }

    // MARK: Browser round-trip

    /// Opens Spotify's consent page and returns the authorization code.
    @MainActor
    static func authorize(clientID: String, verifier: String,
                          anchor: NSWindow?) async throws -> String {
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        guard let url = authorizeURL(clientID: clientID,
                                     challenge: PKCE.challenge(for: verifier),
                                     state: state)
        else { throw AuthError.badClientID }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cancelled)
                }
            }
            // An accessory app has no key window, so the session has to be told what to
            // present over; without an anchor it refuses to start.
            session.presentationContextProvider = Anchor.shared.using(anchor)
            session.prefersEphemeralWebBrowserSession = false
            Anchor.shared.retain(session)
            session.start()
        }

        guard let code = code(from: callback, expectedState: state) else {
            throw AuthError.stateMismatch
        }
        return code
    }

    // MARK: Token exchange

    struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    static func exchange(code: String, verifier: String, clientID: String) async throws -> Tokens {
        try await token(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])
    }

    static func refresh(_ refreshToken: String, clientID: String) async throws -> Tokens {
        try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private static func token(form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(encode(form).utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.rejected(String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    /// Form encoding. `URLComponents` is not used because it leaves `+` alone, and a `+`
    /// in a form body decodes to a space on the server — which silently corrupts tokens.
    static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(escaped)"
        }
        .sorted()
        .joined(separator: "&")
    }

    enum AuthError: Error {
        case badClientID
        case cancelled
        case stateMismatch
        case rejected(String)
    }

    /// Keeps the session alive for its lifetime and answers its "where do I present?"
    /// question. `ASWebAuthenticationSession` is released the moment nothing holds it,
    /// which cancels the sign-in before the browser even opens.
    @MainActor
    final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = Anchor()
        private var window: NSWindow?
        private var session: ASWebAuthenticationSession?

        func using(_ window: NSWindow?) -> Anchor {
            self.window = window
            return self
        }

        func retain(_ session: ASWebAuthenticationSession) {
            self.session = session
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            window ?? NSApp.windows.first ?? NSWindow()
        }
    }
}

/// Token storage in the login Keychain, driven through the `security` CLI.
///
/// The same choice `UsageService.readToken` documents: `SecItemCopyMatching` from an
/// unsigned or re-signed development build triggers a per-app Keychain confirmation
/// dialog, while the CLI does not.
enum SpotifyKeychain {
    private static let service = "ClaudeNotch Spotify"
    private static let account = "refresh-token"

    static func readRefreshToken() -> String? {
        let output = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard let output, !output.isEmpty else { return nil }
        return output
    }

    static func write(refreshToken: String) {
        // -U updates in place; without it a second sign-in fails with "item already exists".
        _ = run(["add-generic-password", "-U", "-s", service, "-a", account,
                 "-w", refreshToken])
    }

    static func clear() {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
