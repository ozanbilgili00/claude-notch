import SwiftUI

/// Preferences window. Phase 0 stub with the settings surface the spec calls for;
/// wiring (hook install/uninstall, hotkeys, permission rules) lands in later phases.
struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("autoLaunch") private var autoLaunch = false
    @AppStorage("autoCollapse") private var autoCollapse = true
    @AppStorage("compactMode") private var compactMode = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("interceptPermissions") private var interceptPermissions = true
    @AppStorage("interceptQuestions") private var interceptQuestions = true

    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hookError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $autoLaunch)
            }
            Section("Notch") {
                Toggle("Auto-collapse when idle", isOn: $autoCollapse)
                Toggle("Compact mode", isOn: $compactMode)
            }
            Section("Alerts") {
                Toggle("Notifications", isOn: $notifications)
            }
            Section("Notch interaction") {
                Toggle("Answer permissions in notch", isOn: $interceptPermissions)
                Toggle("Answer questions in notch", isOn: $interceptQuestions)
                Text("When on, permission prompts and Claude's questions (in default permission mode) are handled in the notch instead of the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code integration") {
                LabeledContent("Observer hooks") {
                    HStack(spacing: 8) {
                        Text(hooksInstalled ? "Installed" : "Not installed")
                            .foregroundStyle(hooksInstalled ? .green : .secondary)
                        Button(hooksInstalled ? "Remove" : "Install") { toggleHooks() }
                    }
                }
                if let error = hookError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Adds observer hooks to ~/.claude/settings.json so the notch can see your Claude Code sessions. Your other settings are preserved; removing is safe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func toggleHooks() {
        do {
            if hooksInstalled { try HookInstaller.uninstall() }
            else { try HookInstaller.install() }
            hooksInstalled = HookInstaller.isInstalled()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }

    private var about: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid.fill").font(.largeTitle)
            Text("Claude Notch").font(.headline)
            Text("A native companion for Claude Code that lives in the notch.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("v0.1 · \(store.sessions.count) sessions observed")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
