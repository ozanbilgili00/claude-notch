import AppKit
import Observation

/// Reads and drives the Spotify desktop app.
///
/// The cost model matters more than the feature here — this app sits in the menu bar on
/// every Space, all day, and its documented rule is that nothing spins while idle. So:
///
/// 1. **Spotify not running → this object does nothing at all.** Detection is
///    `NSRunningApplication`, which is a free local lookup: no Apple Event, no Automation
///    prompt, no subprocess. Launch/quit notifications wake it up and put it back to sleep.
/// 2. **Playback changes arrive by push**, via Spotify's `PlaybackStateChanged`
///    distributed notification. Play, pause and track changes cost zero polling.
/// 3. **Position is extrapolated locally.** One `player position` read seeds a clock and
///    the rest is arithmetic. Polling that property once a second — a subprocess per
///    second — would be by far the most expensive thing the app does.
@MainActor
@Observable
final class SpotifyService {

    private static let bundleID = "com.spotify.client"
    /// Undocumented but long-standing: Spotify posts this on every play/pause/track change.
    private static let playbackChanged = Notification.Name("com.spotify.client.PlaybackStateChanged")

    /// True while the Spotify app is running. Everything in the UI keys off this, so a Mac
    /// without Spotify open sees no music tab and pays nothing.
    private(set) var isRunning = false
    private(set) var track: SpotifyTrack?
    private(set) var isPlaying = false
    /// 0–100, Spotify's own scale.
    private(set) var volume: Int = 100
    private(set) var isShuffling = false
    private(set) var isRepeating = false

    /// Whether the user has the integration switched on at all (Settings → Music).
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "spotifyEnabled")
            if enabled { start() } else { stop() }
        }
    }

    /// Last position read from Spotify, and the instant it was read. `position` below
    /// advances from these rather than asking again.
    private var anchorPosition: TimeInterval = 0
    private var anchorDate = Date()

    private var observers: [NSObjectProtocol] = []
    private var resyncTask: Task<Void, Never>?
    /// Non-zero while a music view is on screen; only then is a periodic re-sync worth it.
    private var liveViewers = 0

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "spotifyEnabled") == nil { defaults.set(true, forKey: "spotifyEnabled") }
        enabled = defaults.bool(forKey: "spotifyEnabled")
        if enabled { start() }
    }

    // MARK: Playback position

    /// Where playback is right now, in seconds. Derived from the last anchor so it stays
    /// smooth between events without asking Spotify anything.
    var position: TimeInterval {
        guard isPlaying else { return anchorPosition }
        let elapsed = Date().timeIntervalSince(anchorDate)
        guard let duration = track?.duration else { return anchorPosition + elapsed }
        return min(anchorPosition + elapsed, duration)
    }

    // MARK: Lifecycle

    private func start() {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        // Launch/quit of *any* app; cheap to filter, and it means the music tab appears
        // the moment Spotify opens without anything polling for it.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Self.playbackChanged, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.handlePlaybackNotification(note) }
            }
        )
        refreshRunning()
    }

    private func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        resyncTask?.cancel()
        resyncTask = nil
        isRunning = false
        track = nil
        isPlaying = false
    }

    private func refreshRunning() {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID)
            .isEmpty == false
        guard running != isRunning else { return }
        isRunning = running
        if running {
            reload()
        } else {
            track = nil
            isPlaying = false
            resyncTask?.cancel()
            resyncTask = nil
        }
    }

    /// The notification carries player state and track identity but never an artwork URL,
    /// so it is used as a trigger rather than as the data source.
    private func handlePlaybackNotification(_ note: Notification) {
        if !isRunning { refreshRunning() }
        reload()
    }

    // MARK: Reading state

    /// One `osascript` round-trip for the whole picture, one field per line.
    ///
    /// Newlines rather than a delimiter character: a control character such as U+001F
    /// inside an AppleScript string literal is a compile error, and no track name, artist
    /// or album can contain a line break, so splitting on them is unambiguous.
    ///
    /// The variable names matter too — `st` is a reserved token in AppleScript and makes
    /// the whole script fail to compile with "expected expression".
    nonisolated private static let readScript = """
    if application "Spotify" is not running then
        return "notrunning"
    end if
    tell application "Spotify"
        set pState to player state as text
        set pPos to player position
        set pVol to sound volume
        set pShuf to shuffling
        set pRep to repeating
        try
            set tr to current track
            return pState & linefeed & pPos & linefeed & (id of tr) & linefeed \
                & (name of tr) & linefeed & (artist of tr) & linefeed \
                & (album of tr) & linefeed & (duration of tr) & linefeed & (artwork url of tr) \
                & linefeed & pVol & linefeed & pShuf & linefeed & pRep & linefeed & (spotify url of tr)
        on error
            return pState & linefeed & pPos & linefeed & "notrack"
        end try
    end tell
    """

    /// Until Spotify has answered once, allow for the Automation consent dialog sitting
    /// on screen; after that a read is local and fast, so keep the watchdog tight.
    private var hasEverRead = false

    func reload() {
        guard enabled, isRunning else { return }
        let timeout: TimeInterval = hasEverRead ? 4 : 25
        Task.detached(priority: .utility) {
            let raw = AppleScriptRunner.run(Self.readScript, timeout: timeout)
            await MainActor.run { self.apply(raw) }
        }
    }

    private func apply(_ raw: String?) {
        guard let raw, raw != "notrunning" else {
            if raw == "notrunning" { isRunning = false; track = nil; isPlaying = false }
            return
        }
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 2 else { return }
        hasEverRead = true

        isPlaying = parts[0] == "playing"
        // AppleScript formats reals with the *locale's* decimal separator, so a Turkish
        // system hands back "12,4" and a plain Double(_:) init returns nil on it.
        anchorPosition = Self.parseNumber(parts[1]) ?? 0
        anchorDate = Date()

        guard parts.count >= 8 else { track = nil; return }
        let durationMS = Self.parseNumber(parts[6]) ?? 0
        let newTrack = SpotifyTrack(
            id: parts[2],
            name: parts[3],
            artist: parts[4],
            album: parts[5],
            duration: durationMS / 1000,
            artworkURL: URL(string: parts[7]),
            // Read defensively rather than with a wider `parts.count` guard: the tail is
            // where fields get appended over time, and a track should still show up if a
            // future Spotify build stops answering one of them.
            spotifyURL: parts.count > 11 ? URL(string: parts[11]) : nil
        )
        if newTrack != track { track = newTrack }

        if parts.count > 8, let vol = Self.parseNumber(parts[8]) {
            // Skipped while the user is mid-drag, or the slider would jump back to
            // whatever the last round-trip reported.
            if !isAdjustingVolume { volume = Int(vol) }
        }
        if parts.count > 9 { isShuffling = parts[9] == "true" }
        if parts.count > 10 { isRepeating = parts[10] == "true" }
        scheduleResync()
    }

    /// Accepts both "12.4" and "12,4" — see the note at the call site.
    nonisolated static func parseNumber(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    // MARK: Re-sync while visible

    /// A music view calls this while it is on screen. Spotify can be scrubbed from its own
    /// window or a keyboard media key without posting a notification, so the extrapolated
    /// clock needs an occasional correction — but only while someone is looking.
    func addViewer() {
        liveViewers += 1
        reload()
        scheduleResync()
    }

    func removeViewer() {
        liveViewers = max(0, liveViewers - 1)
        if liveViewers == 0 {
            resyncTask?.cancel()
            resyncTask = nil
        }
    }

    private func scheduleResync() {
        // Deliberately not gated on `isPlaying`: scrubbing a *paused* track is exactly the
        // case where nothing else tells us the position moved, since Spotify posts no
        // notification for a seek.
        guard liveViewers > 0, resyncTask == nil else { return }
        resyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.liveViewers > 0 else { return }
                self.reload()
            }
        }
    }

    // MARK: Controls

    /// True while a volume drag is in flight; see `apply(_:)`.
    private var isAdjustingVolume = false

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, track?.duration ?? seconds))
        // Move the local clock immediately so the lyrics jump with the click instead of
        // waiting for the round-trip.
        anchorPosition = clamped
        anchorDate = Date()
        // A period is forced: AppleScript parses source with the *system* decimal
        // separator, and "set player position to 12,4" is a syntax error in Turkish.
        command("set player position to \(String(format: "%.3f", clamped).replacingOccurrences(of: ",", with: "."))")
    }

    func toggleShuffle() {
        isShuffling.toggle()
        command("set shuffling to \(isShuffling)")
    }

    func toggleRepeat() {
        isRepeating.toggle()
        command("set repeating to \(isRepeating)")
    }

    /// Called continuously while the slider is dragged: updates the local value only, so
    /// the knob tracks the pointer without starting an `osascript` per pixel.
    func previewVolume(_ value: Int) {
        isAdjustingVolume = true
        volume = max(0, min(100, value))
    }

    /// Called when the drag ends — one round-trip for the whole gesture.
    func commitVolume() {
        isAdjustingVolume = false
        command("set sound volume to \(volume)")
    }

    /// Plays a specific track in the local app. `play track` takes a Spotify URI and needs
    /// no Web API scope and no Premium account, unlike the Web API's playback endpoints.
    func play(uri: String) {
        guard uri.hasPrefix("spotify:") else { return }
        // Spotify brings itself to the front whenever it is told to play a specific track
        // — `tell application` alone does not activate anything, this is Spotify's own
        // doing. That defeats the point of picking a song from the notch: you asked for
        // music and got a full-screen app instead of the thing you were working on. So
        // whoever was in front is noted first and put back once the command has landed.
        //
        // Done with `NSRunningApplication` rather than System Events, which would be the
        // usual AppleScript answer: talking to System Events is a *second* app to automate
        // and would put another macOS consent dialog in the user's way.
        let previous = NSWorkspace.shared.frontmostApplication
        // The quotes are ours to add: `quote` escapes a value for a string literal, it
        // does not wrap it in one. Without them AppleScript reads `play track
        // spotify:track:…` as an expression and the whole command fails to compile.
        command("play track \"\(AppleScriptRunner.quote(uri))\"") {
            guard let previous, previous.bundleIdentifier != Self.bundleID else { return }
            previous.activate()
        }
    }

    func openInSpotify() {
        guard let url = track?.spotifyURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func command(_ body: String, then finish: (@MainActor () -> Void)? = nil) {
        guard enabled, isRunning else { return }
        let script = """
        if application "Spotify" is running then
            tell application "Spotify" to \(body)
        end if
        """
        Task.detached(priority: .userInitiated) {
            let result = AppleScriptRunner.run(script, timeout: 8)
            if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" {
                fputs("[spotify] cmd \(body) -> \(result ?? "nil")\n", stderr)
            }
            // Run first, before the read-back: this is where focus gets handed back, and
            // every millisecond spent waiting is a millisecond of Spotify on screen.
            await MainActor.run { finish?() }
            // Spotify posts PlaybackStateChanged for transport commands, but not for a
            // seek, so read back rather than assume.
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run { self.reload() }
        }
    }
}
