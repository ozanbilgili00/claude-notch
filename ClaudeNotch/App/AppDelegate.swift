import AppKit
import SwiftUI
import UserNotifications
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    private var coordinator: HookCoordinator?
    private var server: HookServer?
    private var usageService: UsageService?
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let hotkeys = HotkeyManager()
    private var discoveryTimer: Timer?

    /// Which question the ⌥1/⌥2/⌥3 hotkeys currently answer, and how many are live.
    private var questionHotkeys: (sessionID: String, count: Int)?

    /// Discovery backs off while nothing is happening; any change snaps it back.
    private var discoveryInterval: TimeInterval = 10
    private var lastDiscoverySignature: String = ""
    private static let discoveryFast: TimeInterval = 10
    private static let discoverySlow: TimeInterval = 30

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

        let usage = UsageService(store: store)
        usageService = usage
        usage.start()

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

        notchController = NotchWindowController(store: store)
        setupMenuBar()

        hotkeys.onToggle = { [weak self] in self?.notchController?.toggle() }
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
            notchController?.expand()
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
        DispatchQueue.global(qos: .utility).async {
            let found = SessionDiscovery.scan(known: known)
            Task { @MainActor [weak self] in
                coord?.applyDiscovered(found)
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
        } onChange: {
            Task { @MainActor [weak self] in
                self?.syncQuestionHotkeys()
                self?.trackPendingQuestion()
            }
        }
        syncQuestionHotkeys()
    }

    private func syncQuestionHotkeys() {
        let pending: (sessionID: String, count: Int)? = store.sessions
            .first { $0.pendingQuestion != nil }
            .map { ($0.id, $0.pendingQuestion!.choices.count) }

        guard pending?.sessionID != questionHotkeys?.sessionID
                || pending?.count != questionHotkeys?.count else { return }

        for index in 1...9 { hotkeys.unregister(id: HotkeyManager.questionID(index: index)) }
        questionHotkeys = pending

        guard let pending else { return }
        // Only bind as many as the question actually offers.
        let keyCodes = [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
                        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5)]
        for index in 1...min(pending.count, keyCodes.count) {
            hotkeys.register(keyCode: keyCodes[index - 1], modifiers: UInt32(optionKey),
                             id: HotkeyManager.questionID(index: index))
        }
    }

    private func handleHotkey(_ id: UInt32) {
        guard id != HotkeyManager.toggleID,
              let pending = questionHotkeys else { return }
        let index = Int(id) - 100
        guard index >= 1, index <= pending.count else { return }
        store.onQuestionAnswer?(pending.sessionID, index)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                     accessibilityDescription: "Claude Notch")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        // Rebuilt on every open (see menuNeedsUpdate): the session count and hook state
        // both go stale otherwise, and it's also what picks up a language change.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: L(.openNotch), action: #selector(openNotch), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let status = menu.addItem(withTitle: statusSummary(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        let hookStatus = menu.addItem(
            withTitle: HookInstaller.isInstalled() ? L(.hooksInstalledMenu)
                                                   : L(.hooksNotInstalledMenu),
            action: nil, keyEquivalent: "")
        hookStatus.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: L(.settingsMenu), action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L(.quitApp), action: #selector(NSApp.terminate(_:)),
                     keyEquivalent: "q")
    }

    private func statusSummary() -> String {
        let n = store.workingCount
        return n > 0 ? Lcount(.workingCountOne, .workingCountMany, n) : L(.statusIdle)
    }

    @objc private func openNotch() { notchController?.expand() }

    /// Focus the session a notification came from.
    func focusSession(_ id: String) {
        guard store.session(id) != nil else { return }
        store.selectedID = id
        notchController?.expand()
    }

    /// The preferences window, owned here rather than left to SwiftUI's `Settings`
    /// scene. Opening that scene means sending the private `showSettingsWindow:` action
    /// down the responder chain, and in an accessory app with no key window there is
    /// nothing to receive it — the menu item simply did nothing.
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView().environment(store))
        let window = NSWindow(contentViewController: hosting)
        // The app name rather than a translated "Settings": the title is set once, so a
        // localized one would sit in the old language after a switch in this very window.
        window.title = "Claude Notch"
        window.styleMask = [.titled, .closable]
        // Closing must not deallocate it, or reopening lands on a freed window.
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
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

extension AppDelegate: NSMenuDelegate {
    /// The status-item menu is built fresh each time it opens. It used to be built once
    /// at launch, so the "N sessions working" line showed whatever was true then — and it
    /// would have kept the launch language after a switch in Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }
}
