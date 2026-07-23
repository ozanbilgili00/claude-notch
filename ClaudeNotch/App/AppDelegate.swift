import AppKit
import SwiftUI

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
            store.selectedID = store.sessions.first?.id
        }
        #endif

        notchController = NotchWindowController(store: store)
        setupMenuBar()

        hotkeys.onToggle = { [weak self] in self?.notchController?.toggle() }
        hotkeys.register()

        // Discover already-running / idle sessions the hooks haven't surfaced yet.
        runDiscovery()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.runDiscovery()
        }
    }

    private func runDiscovery() {
        let coord = coordinator
        DispatchQueue.global(qos: .utility).async {
            let found = SessionDiscovery.scan()
            Task { @MainActor in coord?.applyDiscovered(found) }
        }
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

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
