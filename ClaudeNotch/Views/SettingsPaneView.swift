import SwiftUI
import ServiceManagement
import AppKit

/// Settings, drawn inside the panel instead of in a window of its own.
///
/// A separate preferences window was the wrong shape for this app twice over: an
/// accessory app that never activates can't reliably open one (that is why the gear used
/// to do nothing), and when it did open it landed as a grey system Form floating next to
/// a black panel — two different apps, as far as the eye is concerned. Everything now
/// lives on a tab, in the panel's own idiom.
///
/// Two columns because the panel is 720×360: one long scrolling list would put the
/// switches that matter (layout, rings) below the fold on every open.
struct SettingsPaneView: View {
    @Bindable var spotify: SpotifyService
    @Bindable var shelf: ShelfStore
    @Bindable var web: SpotifyWebAPI
    @Bindable var audio: AudioService
    @Bindable var store: SessionStore

    @AppStorage("dockMode") private var dockMode = DockMode.notch.rawValue
    @AppStorage(ScreenChoice.key) private var screenChoice = "auto"
    @AppStorage("autoLaunch") private var autoLaunch = false
    @AppStorage("autoCollapse") private var autoCollapse = true
    @AppStorage("compactMode") private var compactMode = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("usageAlerts") private var usageAlerts = true
    @AppStorage("eventAnimations") private var eventAnimations = true
    @AppStorage("geminiSessions") private var geminiSessions = true
    @AppStorage("muteSounds") private var muteSounds = false
    @AppStorage("interceptPermissions") private var interceptPermissions = true
    @AppStorage("interceptQuestions") private var interceptQuestions = true
    @AppStorage("showLyrics") private var showLyrics = true
    @AppStorage("showTrackInPill") private var showTrackInPill = true

    @State private var theme = ThemeSettings.shared
    @State private var rules = PermissionRules.shared
    @State private var l10n = Localization.shared
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hookHealth = HookInstaller.health()
    @State private var hookError: String?
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    layoutSection
                    notchSection
                    languageSection
                    startupSection
                    alertsSection
                    rulesSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    musicSection
                    shelfSection
                    soundSection
                    hooksSection
                    aboutSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .onAppear { refreshHookState() }
    }

    // MARK: Sections

    private var layoutSection: some View {
        section(L(.layoutSection)) {
            Picker("", selection: $dockMode) {
                Text(L(.layoutNotch)).tag(DockMode.notch.rawValue)
                Text(L(.layoutEdge)).tag(DockMode.edge.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .onChange(of: dockMode) { _, _ in
                NotificationCenter.default.post(name: .notchLayoutChanged, object: nil)
            }
            note(L(.layoutNote))
            screenPicker
            if dockMode == DockMode.edge.rawValue {
                ForEach(UsageRingKind.allCases) { kind in
                    toggle(kind.title, ringBinding(kind))
                }
                note(L(.edgeRingsNote))
            }
        }
    }

    /// Only offered with more than one display; with one there is nothing to choose.
    @ViewBuilder
    private var screenPicker: some View {
        let screens = NSScreen.screens
        if screens.count > 1 || screenChoice != "auto" {
            HStack(spacing: 8) {
                Text(L(.screenLabel)).font(Theme.caption).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Picker("", selection: $screenChoice) {
                    Text(L(.screenAutomatic)).tag("auto")
                    Text(L(.screenPointer)).tag("pointer")
                    Divider()
                    ForEach(screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(ScreenChoice.display(ScreenPicker.displayID(screen)).raw)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .onChange(of: screenChoice) { _, _ in
                    NotificationCenter.default.post(name: .notchLayoutChanged, object: nil)
                }
            }
        }
    }

    private var notchSection: some View {
        section(L(.sectionNotch)) {
            toggle(L(.autoCollapseWhenIdle), $autoCollapse)
            toggle(L(.eventAnimationsToggle), $eventAnimations)
            toggle(L(.compactMode), $compactMode)
            HStack(spacing: 8) {
                Text(L(.accentColor)).font(Theme.caption).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                // Swatches rather than a Picker: five colours read faster as five dots,
                // and a pop-up menu inside a non-activating panel is one more window to
                // fight with.
                HStack(spacing: 6) {
                    ForEach(ThemeSettings.Accent.allCases) { accent in
                        Button { theme.accent = accent } label: {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle().strokeBorder(
                                        theme.accent == accent ? Theme.text : .clear,
                                        lineWidth: 1.5)
                                        .padding(-2.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(accent.displayName)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var languageSection: some View {
        section(L(.sectionLanguage)) {
            Picker("", selection: Binding(get: { l10n.language },
                                          set: { l10n.language = $0 })) {
                ForEach(Localization.Language.allCases) { lang in
                    Text(lang.endonym).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var startupSection: some View {
        section(L(.sectionStartup)) {
            toggle(L(.launchAtLogin), Binding(get: { autoLaunch },
                                              set: { setLaunchAtLogin($0) }))
            if let loginError {
                Text(loginError).font(Theme.micro).foregroundStyle(Theme.red)
            }
        }
    }

    private var musicSection: some View {
        section(L(.musicSection)) {
            toggle(L(.musicEnable), Binding(get: { spotify.enabled },
                                            set: { spotify.enabled = $0 }))
            toggle(L(.musicShowLyrics), $showLyrics, enabled: spotify.enabled)
            toggle(L(.musicShowInPill), $showTrackInPill, enabled: spotify.enabled)
            HStack(spacing: 8) {
                Text(L(.spotifyClientID)).font(Theme.caption).foregroundStyle(Theme.textDim)
                TextField("", text: Binding(
                    get: { web.clientID },
                    set: { web.clientID = $0.trimmingCharacters(in: .whitespaces) }
                ))
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            }
            HStack(spacing: 8) {
                Text(spotifyStatus)
                    .font(Theme.micro)
                    .foregroundStyle(web.state == .connected ? Theme.green : Theme.dim)
                Spacer()
                if web.state == .connected {
                    linkButton(L(.spotifyDisconnect)) { web.disconnect() }
                } else {
                    linkButton(L(.spotifyConnect)) {
                        Task { await web.connect(anchor: NSApp.keyWindow) }
                    }
                    .disabled(web.clientID.isEmpty || web.state == .connecting)
                }
            }
        }
    }

    private var shelfSection: some View {
        section(L(.shelfSection)) {
            toggle(L(.shelfEnable), Binding(get: { shelf.enabled },
                                            set: { shelf.enabled = $0 }))
        }
    }

    private var soundSection: some View {
        section(L(.mixerSection)) {
            toggle(L(.mixerEnableTaps), Binding(get: { audio.tapsEnabled },
                                                set: { audio.tapsEnabled = $0 }))
            note(L(.mixerTapsNote))
        }
    }

    private var alertsSection: some View {
        section(L(.sectionAlerts)) {
            toggle(L(.sounds), Binding(get: { !muteSounds }, set: { muteSounds = !$0 }))
            toggle(L(.notifications), $notifications)
            toggle(L(.usageAlertsToggle), $usageAlerts)
            toggle(L(.answerPermissionsInNotch), $interceptPermissions)
            toggle(L(.answerQuestionsInNotch), $interceptQuestions)
        }
    }

    /// Every saved "Always Allow", removable one at a time. Old first-word Bash rules are
    /// flagged: they allow far more than the command that was approved.
    private var rulesSection: some View {
        section(L(.rulesSection)) {
            if rules.all.isEmpty {
                note(L(.rulesEmpty))
            } else {
                ForEach(rules.all) { rule in
                    HStack(spacing: 6) {
                        Image(systemName: rule.tool == "Bash" ? "terminal" : "pencil")
                            .font(.system(size: 9)).foregroundStyle(Theme.dim)
                            .frame(width: 12)
                        Text(rule.coversWholeTool ? "\(rule.tool) · \(L(.rulesAllUses))" : rule.pattern)
                            .font(Theme.caption).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        if rule.legacy {
                            Badge(text: L(.rulesLegacy), tint: Theme.amber)
                                .help(L(.rulesLegacyHint))
                        }
                        Spacer(minLength: 4)
                        Button {
                            withAnimation(Theme.Motion.quick) { rules.remove(rule) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10)).foregroundStyle(Theme.dim)
                        }
                        .buttonStyle(.plain)
                        .help(L(.rulesRemove))
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                linkButton(L(.rulesClearAll)) {
                    withAnimation(Theme.Motion.quick) { rules.removeAll() }
                }
            }
        }
    }

    private var hooksSection: some View {
        section(L(.sectionIntegration)) {
            HStack(spacing: 8) {
                Image(systemName: hooksInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10))
                    .foregroundStyle(hooksInstalled ? Theme.green : Theme.dim)
                Text(L(.observerHooks)).font(Theme.caption).foregroundStyle(Theme.text)
                Spacer()
                linkButton(hooksInstalled ? L(.remove) : L(.install)) { toggleHooks() }
            }
            if let hookError {
                Text(hookError).font(Theme.micro).foregroundStyle(Theme.red)
            }
            mismatchWarning
            toggle(L(.geminiSessionsToggle), $geminiSessions)
            if case .outdated(let missing) = hookHealth {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L(.hooksOutdated), systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.micro.weight(.semibold)).foregroundStyle(Theme.amber)
                    Text(missing.joined(separator: ", "))
                        .font(Theme.micro).foregroundStyle(Theme.dim).lineLimit(2)
                    linkButton(L(.hooksUpdate)) { toggleHooks(forceInstall: true) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.amber.opacity(0.12)))
            }
        }
    }

    /// The failure this app is most likely to hit: settings.json still invokes an older
    /// copy (a stale Xcode build, or one that's since been deleted), so hooks quietly
    /// reach a binary that isn't the one you're looking at — or nothing at all.
    @ViewBuilder
    private var mismatchWarning: some View {
        if case .pointsElsewhere(let path, let exists) = hookHealth {
            VStack(alignment: .leading, spacing: 4) {
                Label(exists ? L(.hooksPointElsewhere) : L(.hooksPointMissing),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.micro.weight(.semibold))
                    .foregroundStyle(exists ? Theme.amber : Theme.red)
                Text(path)
                    .font(Theme.micro).foregroundStyle(Theme.dim)
                    .lineLimit(2).truncationMode(.middle)
                linkButton(L(.pointAtThisCopy)) { toggleHooks(forceInstall: true) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill((exists ? Theme.amber : Theme.red).opacity(0.12)))
        }
    }

    private var aboutSection: some View {
        section(L(.tabAbout)) {
            Text("\(AppInfo.version) · "
                 + Lcount(.sessionsObservedOne, .sessionsObservedMany, store.sessions.count))
                .font(Theme.micro).foregroundStyle(Theme.dim)
            // Which copy is running and how it's signed. A stable signature is what keeps
            // macOS from re-asking for notification / automation access on every rebuild.
            Text(L(.signedBy, AppInfo.originLabel,
                   AppInfo.signingAuthority ?? L(.signedByNobody)))
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .lineLimit(2)
            linkButton(L(.quitApp)) { NSApp.terminate(nil) }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        )
                )
        }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>,
                        enabled: Bool = true) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(Theme.caption)
                .foregroundStyle(enabled ? Theme.text : Theme.dim)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.green)
        .disabled(!enabled)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.micro).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func linkButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.micro.weight(.medium)).foregroundStyle(Theme.blue)
        }
        .buttonStyle(.plain)
    }

    // MARK: State

    private var spotifyStatus: String {
        switch web.state {
        case .needsSetup:  return L(.spotifyNeedsSetup)
        case .signedOut:   return L(.spotifySignedOut)
        case .connecting:  return L(.spotifyConnecting)
        case .connected:   return L(.spotifyConnected)
        case .expired:     return L(.spotifyExpired)
        }
    }

    /// Reads and writes the stored ring list through `UsageRingKind`, so the ordering rule
    /// (always `allCases`, never the order they were switched on) lives in one place.
    private func ringBinding(_ kind: UsageRingKind) -> Binding<Bool> {
        Binding(
            get: { UsageRingKind.enabled().contains(kind) },
            set: { isOn in
                var rings = UsageRingKind.enabled()
                if isOn { rings.append(kind) } else { rings.removeAll { $0 == kind } }
                UsageRingKind.setEnabled(rings)
                NotificationCenter.default.post(name: .notchLayoutChanged, object: nil)
            }
        )
    }

    /// Register the app itself as a login item. Leaves the switch off if macOS refuses,
    /// so it never claims something that isn't true.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            autoLaunch = on
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
}
