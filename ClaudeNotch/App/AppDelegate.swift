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

    // MARK: Discovery

    private func scheduleDiscovery() {
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: discoveryInterval,
                                              repeats: true) { [weak self] _ in
            self?.runDiscovery()
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
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Notch", action: #selector(openNotch), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let status = menu.addItem(withTitle: statusSummary(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        let hookStatus = menu.addItem(
            withTitle: HookInstaller.isInstalled() ? "Hooks: installed" : "Hooks: not installed",
            action: nil, keyEquivalent: "")
        hookStatus.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Notch", action: #selector(NSApp.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    private func statusSummary() -> String {
        let n = store.workingCount
        return n > 0 ? "\(n) session\(n == 1 ? "" : "s") working" : "Idle"
    }

    @objc private func openNotch() { notchController?.expand() }

    /// Focus the session a notification came from.
    func focusSession(_ id: String) {
        guard store.session(id) != nil else { return }
        store.selectedID = id
        notchController?.expand()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
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
