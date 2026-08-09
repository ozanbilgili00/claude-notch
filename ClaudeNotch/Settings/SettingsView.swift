import SwiftUI
import ServiceManagement

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

    @State private var theme = ThemeSettings.shared
    @State private var l10n = Localization.shared
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hookHealth = HookInstaller.health()
    @State private var hookError: String?
    @State private var loginError: String?

    var body: some View {
        TabView {
            general.tabItem { Label(L(.tabGeneral), systemImage: "gearshape") }
            about.tabItem { Label(L(.tabAbout), systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }

    private var general: some View {
        Form {
            Section(L(.sectionLanguage)) {
                // Each language is named in itself, so it stays findable whichever one
                // the app happens to be showing.
                Picker(L(.sectionLanguage), selection: Binding(
                    get: { l10n.language },
                    set: { l10n.language = $0 }
                )) {
                    ForEach(Localization.Language.allCases) { lang in
                        Text(lang.endonym).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section(L(.sectionStartup)) {
                Toggle(L(.launchAtLogin), isOn: $autoLaunch)
                    .onChange(of: autoLaunch) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section(L(.sectionNotch)) {
                Toggle(L(.autoCollapseWhenIdle), isOn: $autoCollapse)
                Toggle(L(.compactMode), isOn: $compactMode)
                Picker(L(.accentColor), selection: Binding(
                    get: { theme.accent },
                    set: { theme.accent = $0 }
                )) {
                    ForEach(ThemeSettings.Accent.allCases) { accent in
                        HStack {
                            Circle().fill(accent.color).frame(width: 10, height: 10)
                            Text(accent.displayName)
                        }
                        .tag(accent)
                    }
                }
                Text(L(.accentNote))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L(.sectionAlerts)) {
                Toggle(L(.notifications), isOn: $notifications)
            }
            Section(L(.sectionNotchInteraction)) {
                Toggle(L(.answerPermissionsInNotch), isOn: $interceptPermissions)
                Toggle(L(.answerQuestionsInNotch), isOn: $interceptQuestions)
                Text(L(.interceptNote))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L(.sectionIntegration)) {
                LabeledContent(L(.observerHooks)) {
                    HStack(spacing: 8) {
                        Text(hooksInstalled ? L(.installed) : L(.notInstalled))
                            .foregroundStyle(hooksInstalled ? .green : .secondary)
                        Button(hooksInstalled ? L(.remove) : L(.install)) { toggleHooks() }
                    }
                }
                if let error = hookError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                mismatchWarning
                Text(L(.hooksNote))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshHookState() }
    }

    /// The failure this app is most likely to hit: settings.json still invokes an older
    /// copy (a stale Xcode build, or one that's since been deleted), so hooks quietly
    /// reach a binary that isn't the one you're looking at — or nothing at all.
    @ViewBuilder
    private var mismatchWarning: some View {
        if case .pointsElsewhere(let path, let exists) = hookHealth {
            VStack(alignment: .leading, spacing: 6) {
                Label(exists ? L(.hooksPointElsewhere) : L(.hooksPointMissing),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(exists ? .orange : .red)
                Text(path)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Button(L(.pointAtThisCopy)) { toggleHooks(forceInstall: true) }
                    .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill((exists ? Color.orange : Color.red).opacity(0.12)))
        }
    }

    /// Register the app itself as a login item. Reverts the toggle if macOS refuses,
    /// so the switch never claims something that isn't true.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            autoLaunch = !on
        }
    }

    private func toggleHooks(forceInstall: Bool = false) {
        do {
            if hooksInstalled && !forceInstall { try HookInstaller.uninstall() }
            else { try HookInstaller.install() }
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookState()
    }

    private func refreshHookState() {
        hooksInstalled = HookInstaller.isInstalled()
        hookHealth = HookInstaller.health()
    }

    private var about: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid.fill").font(.largeTitle)
            Text("Claude Notch").font(.headline)
            Text(L(.aboutTagline))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("\(AppInfo.version) · "
                 + Lcount(.sessionsObservedOne, .sessionsObservedMany, store.sessions.count))
                .font(.caption2).foregroundStyle(.secondary)
            // Which copy is running and how it's signed. A stable signature is what
            // keeps macOS from re-asking for notification / automation access on
            // every rebuild, so it's worth being able to see it at a glance.
            Text(L(.signedBy, AppInfo.originLabel, AppInfo.signingAuthority ?? L(.signedByNobody)))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
