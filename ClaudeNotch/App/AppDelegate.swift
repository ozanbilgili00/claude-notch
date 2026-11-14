import AppKit
import SwiftUI
import UserNotifications
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let spotify = SpotifyService()
    let shelf = ShelfStore()
    let spotifyWeb = SpotifyWebAPI()
    let audio = AudioService()
    private var coordinator: HookCoordinator?
    private var server: HookServer?
    private var usageService: UsageService?
    private var tokenLedger: TokenLedger?
    private var notchController: NotchWindowController?
    private var edgeController: EdgeWindowController?
    private let hotkeys = HotkeyManager()
    private var discoveryTimer: Timer?

    /// Which question the ⌥1/⌥2/⌥3 hotkeys currently answer, and how many are live.
    private var questionHotkeys: (sessionID: String, count: Int)?
    /// Which session's permission request ⌥Y / ⌥⇧Y / ⌥N currently answer.
    private var permissionHotkeysFor: String?

    /// Discovery backs off while nothing is happening; any change snaps it back.
    private var discoveryInterval: TimeInterval = 10
    private var lastDiscoverySignature: String = ""
    private static let discoveryFast: TimeInterval = 10
    private static let discoverySlow: TimeInterval = 30

    /// One-shot check that the Web API actually answers for this account, before any of
    /// the search or queue UI is built on top of it. `NOTCH_SPOTIFY_PROBE=1` only.
    private func runSpotifyProbeIfAsked() {
        guard ProcessInfo.processInfo.environment["NOTCH_SPOTIFY_PROBE"] == "1" else { return }
        Task { @MainActor in
            let log: (String) -> Void = { line in fputs("[probe] \(line)\n", stderr) }
            log("state=\(self.spotifyWeb.state) clientID=\(self.spotifyWeb.clientID.isEmpty ? "yok" : "var")")
            if self.spotifyWeb.state != .connected {
                await self.spotifyWeb.connect(anchor: NSApp.windows.first)
                log("after connect: state=\(self.spotifyWeb.state)")
            }
            let results = await self.spotifyWeb.search("kalben")
            log("search → \(results.count) sonuç; ilk: \(results.first.map { "\($0.artist) — \($0.name)" } ?? "-")")
            let queue = await self.spotifyWeb.queue()
            log("queue → \(queue.count) parça; ilk: \(queue.first?.name ?? "-")")
            let recent = await self.spotifyWeb.recentlyPlayed()
            log("recent → \(recent.count) parça; ilk: \(recent.first?.name ?? "-")")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Live pipeline: coordinator folds hook events into the store; server listens
        // on the unix socket for the `--hook` client.
        let coord = HookCoordinator(store: store)
        coordinator = coord
        let srv = HookServer(coordinator: coord)
        server = srv
        srv.onAppControl = { [weak self] control in self?.handleAppControl(control) }
        srv.start()

        runSpotifyProbeIfAsked()

        let usage = UsageService(store: store)
        usageService = usage
        usage.start()

        let ledger = TokenLedger(store: store)
        tokenLedger = ledger
        ledger.start()

        #if DEBUG
        // Fire app events by hand to watch their animations without a real session:
        // post "com.ozan.ClaudeNotch.debugEvent" with object completed / failed /
        // attention / warning / reset. Debug builds only.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ozan.ClaudeNotch.debugEvent"), object: nil, queue: .main
        ) { [weak self] note in
            let kind: NotchEvent.Kind = switch note.object as? String {
            case "failed":    .failed
            case "attention": .attention
            case "warning":   .usageWarning
            case "reset":     .usageReset
            default:          .completed
            }
            MainActor.assumeIsolated { self?.store.signal(kind, session: self?.store.sessions.first?.id) }
        }
        #endif

        // Mock data is now opt-in (NOTCH_MOCK=1) since real sessions drive the UI.
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCH_MOCK"] == "1" {
            var mock = MockData.sessions
            if ProcessInfo.processInfo.environment["NOTCH_MOCK_BLOCK"] == "0" {
                for i in mock.indices {
                    mock[i].pendingQuestion = nil
                    mock[i].pendingPermission = nil
                    if mock[i].status == .waiting { mock[i].status = .working }
                }
            }
            store.sessions = mock
            store.usage = MockData.usage
            // Same rule as the live path: only jump straight into a session on request.
            if ProcessInfo.processInfo.environment["NOTCH_FOCUS_FIRST"] == "1" {
                store.selectedID = store.sessions.first?.id
            }
        }
        #endif

        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestAuthorization()

        installLayout(UserDefaults.standard.dockMode)
        observeDisplays()
        observeLayoutChanges()

        hotkeys.onToggle = { [weak self] in self?.toggleLayout() }
        hotkeys.onHotkey = { [weak self] id in self?.handleHotkey(id) }
        hotkeys.register()
        trackPendingQuestion()

        // Discover already-running / idle sessions the hooks haven't surfaced yet.
        runDiscovery()
        scheduleDiscovery()
    }

    // MARK: App-level control messages

    /// `ping` / `show` / `quit` arrive on the same socket as hook events; anything else
    /// returns nil so the coordinator can handle it (e.g. `resolve`).
    private func handleAppControl(_ control: String) -> [String: Any]? {
        switch control {
        case "ping":
            return ["ok": true,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "path": AppInfo.executablePath,
                    "version": AppInfo.version]
        case "show":
            if let edgeController { edgeController.expand() } else { notchController?.expand() }
            return ["ok": true]
        case "quit":
            // Reply first, then leave — the caller is usually an installer waiting to
            // replace this bundle underneath us.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                NSApp.terminate(nil)
            }
            return ["ok": true]
        default:
            return nil
        }
    }

    // MARK: Discovery

    private func scheduleDiscovery() {
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: discoveryInterval,
                                              repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDiscovery() }
        }
    }

    private func runDiscovery() {
        let coord = coordinator
        let store = self.store
        // Sessions the hooks already own; discovery shouldn't re-guess their transcripts.
        let known = Set(store.sessions.filter { $0.transcriptPath != nil }.map(\.id))
        let withGemini = UserDefaults.standard.geminiSessionsEnabled
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = SessionDiscovery.scan(known: known)
            let gemini = withGemini ? GeminiDiscovery.scan() : []
            Task { @MainActor in
                coord?.applyDiscovered(found, gemini: gemini)
                if ProcessInfo.processInfo.environment["NOTCH_FOCUS_FIRST"] == "1",
                   store.selectedID == nil { store.selectedID = store.sessions.first?.id }
                self?.adjustDiscoveryPace(found)
            }
        }
    }

    /// Polling costs three subprocesses (`pgrep`/`lsof`/`ps`) a round, so slow down once
    /// the picture stops changing and nothing is actively working.
    private func adjustDiscoveryPace(_ found: [SessionDiscovery.Found]) {
        let signature = found.map { "\($0.id):\($0.pid)" }.sorted().joined(separator: ",")
        let changed = signature != lastDiscoverySignature
        lastDiscoverySignature = signature

        let busy = store.workingCount > 0 || store.blockingSession != nil
        let target = (changed || busy) ? Self.discoveryFast : Self.discoverySlow
        guard target != discoveryInterval else { return }
        discoveryInterval = target
        scheduleDiscovery()
    }

    // MARK: Question hotkeys (⌥1 / ⌥2 / ⌥3)

    /// Keep the numbered hotkeys registered exactly while a question is on screen, so
    /// they can be answered without focusing the notch — and don't steal ⌥1 otherwise.
    private func trackPendingQuestion() {
        withObservationTracking {
            _ = store.blockingSession?.pendingQuestion?.id
            _ = store.blockingSession?.pendingQuestion?.choices.count
            _ = store.sessions.map { $0.pendingPermission?.id }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncQuestionHotkeys()
                self?.trackPendingQuestion()
            }
        }
        syncQuestionHotkeys()
    }

    private func syncQuestionHotkeys() {
        syncPermissionHotkeys()
        let pending: (sessionID: String, count: Int)? = store.sessions
            .first { $0.pendingQuestion != nil }
            .map { ($0.id, $0.pendingQuestion!.choices.count) }

        guard pending?.sessionID != questionHotkeys?.sessionID
                || pending?.count != questionHotkeys?.count else { return }

        for index in 1...9 { hotkeys.unregister(id: HotkeyManager.questionID(index: index)) }
        questionHotkeys = pending

        guard let pending else { return }
        // Only bind as many as the question actually offers.
        let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(UInt32.init)
        for index in 1...min(pending.count, keyCodes.count) {
            hotkeys.register(keyCode: keyCodes[index - 1], modifiers: UInt32(optionKey),
                             id: HotkeyManager.questionID(index: index))
        }
    }

    /// Same lifetime rule as the question keys: bound only while a request waits, so ⌥Y
    /// and ⌥N type their usual characters the rest of the time.
    private func syncPermissionHotkeys() {
        let pending = store.sessions.first { $0.pendingPermission != nil }?.id
        guard pending != permissionHotkeysFor else { return }
        permissionHotkeysFor = pending
        let ids = [HotkeyManager.allowOnceID, HotkeyManager.alwaysAllowID, HotkeyManager.denyID]
        ids.forEach { hotkeys.unregister(id: $0) }
        guard pending != nil else { return }
        let option = UInt32(optionKey)
        hotkeys.register(keyCode: UInt32(kVK_ANSI_Y), modifiers: option, id: HotkeyManager.allowOnceID)
        hotkeys.register(keyCode: UInt32(kVK_ANSI_Y), modifiers: option | UInt32(shiftKey),
                         id: HotkeyManager.alwaysAllowID)
        hotkeys.register(keyCode: UInt32(kVK_ANSI_N), modifiers: option, id: HotkeyManager.denyID)
    }

    private func handleHotkey(_ id: UInt32) {
        if let sessionID = permissionHotkeysFor {
            let decision: PermissionDecision? = switch id {
            case HotkeyManager.allowOnceID:   .allowOnce
            case HotkeyManager.alwaysAllowID: .alwaysAllow
            case HotkeyManager.denyID:        .deny
            default:                          nil
            }
            if let decision {
                store.onPermissionDecision?(sessionID, decision)
                return
            }
        }
        guard id != HotkeyManager.toggleID,
              let pending = questionHotkeys else { return }
        let index = Int(id) - 100
        guard index >= 1, index <= pending.count else { return }
        store.onQuestionAnswer?(pending.sessionID, index)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        // Every tapped app is muted at the source while we hold its tap; leaving without
        // releasing them would take their sound with us.
        audio.releaseAllTaps()
    }

    /// Focus the session a notification came from.
    func focusSession(_ id: String) {
        guard store.session(id) != nil else { return }
        store.selectedID = id
        if let edgeController { edgeController.focus(id) } else { notchController?.expand() }
    }

    // MARK: Layout

    /// Builds the window for one layout and tears the other one down. Only ever one is
    /// alive: two panels showing the same sessions would fight over the hotkey, the
    /// blocking-event hold and the file drops.
    private func installLayout(_ mode: DockMode) {
        notchController?.close()
        notchController = nil
        edgeController?.close()
        edgeController = nil
        let screen = ScreenPicker.screen(for: mode)
        layoutScreen = (ScreenPicker.displayID(screen), screen.frame)
        switch mode {
        case .notch:
            notchController = NotchWindowController(store: store, spotify: spotify, shelf: shelf,
                                                    web: spotifyWeb, audio: audio, screen: screen)
        case .edge:
            edgeController = EdgeWindowController(store: store, spotify: spotify, shelf: shelf,
                                                  web: spotifyWeb, audio: audio, screen: screen)
        }
    }

    // MARK: Displays

    /// The display the current layout was built on, and its frame then — a resolution or
    /// arrangement change on the same display also needs a rebuild in notch mode.
    private var layoutScreen: (id: UInt32, frame: CGRect)?
    private var pointerFollow: Timer?

    private var layoutIsIdle: Bool {
        (notchController?.isIdle ?? true) && (edgeController?.isIdle ?? true)
            && store.blockingSession == nil
    }

    /// Rebuild on another display when the choice now points elsewhere. Only while
    /// nothing is open: a panel must not vanish from under the pointer mid-answer.
    private func relocateIfNeeded(force: Bool = false) {
        let mode = UserDefaults.standard.dockMode
        let screen = ScreenPicker.screen(for: mode)
        let id = ScreenPicker.displayID(screen)
        guard force || id != layoutScreen?.id || screen.frame != layoutScreen?.frame else { return }
        guard force || layoutIsIdle else { return }
        installLayout(mode)
    }

    private func observeDisplays() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocateIfNeeded() }
        }
        syncPointerFollow()
    }

    /// "Follow the pointer" needs a poll: there is no notification for the mouse crossing
    /// to another display, and a global mouse-moved monitor would fire constantly.
    private func syncPointerFollow() {
        pointerFollow?.invalidate()
        pointerFollow = nil
        guard ScreenChoice.stored == .pointer, NSScreen.screens.count > 1 else { return }
        pointerFollow = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocateIfNeeded() }
        }
    }

    /// The setting is a plain `UserDefaults` value written by the Settings window, so this
    /// listens for the change rather than being called from it.
    private func observeLayoutChanges() {
        NotificationCenter.default.addObserver(
            forName: .notchLayoutChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mode = UserDefaults.standard.dockMode
                let alreadyRight = (mode == .notch && self.notchController != nil)
                    || (mode == .edge && self.edgeController != nil)
                self.syncPointerFollow()
                let wanted = ScreenPicker.displayID(ScreenPicker.screen(for: mode))
                if alreadyRight && wanted != self.layoutScreen?.id {
                    self.installLayout(mode)
                } else if alreadyRight {
                    // Same layout, different rings: the edge dock resizes itself.
                    self.edgeController?.refreshRings()
                } else {
                    self.installLayout(mode)
                }
            }
        }
    }

    private func toggleLayout() {
        if let edgeController { edgeController.toggle() } else { notchController?.toggle() }
    }

}

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Tapping an alert opens the notch on the session it came from.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let id { self.focusSession(id) }
            completionHandler()
        }
    }

    /// Show our banners even when Claude Notch is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    /// Posted from inside the notch to bring up the preferences window.
    /// Posted when the layout or its rings change in Settings.
    static let notchLayoutChanged = Notification.Name("ClaudeNotch.layoutChanged")
}
