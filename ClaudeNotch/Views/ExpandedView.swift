import SwiftUI

/// The full panel: a usage header, then a stack of session cards. A card that is
/// blocking (permission or question) expands inline to show the diff / choices.
struct ExpandedView: View {
    @Bindable var store: SessionStore
    @Bindable var model: NotchViewModel
    var ns: Namespace.ID

    @State private var showQuickSettings =
        ProcessInfo.processInfo.environment["NOTCH_QUICK_SETTINGS"] == "1"
    /// Keyboard highlight in the list (distinct from `store.selectedID`, which opens
    /// the focused view).
    @State private var highlightedID: String?

    var body: some View {
        VStack(spacing: 0) {
            UsageHeaderView(store: store, showQuickSettings: $showQuickSettings)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            if let id = store.selectedID, let session = store.session(id) {
                FocusedSessionView(
                    store: store, session: session,
                    onDone: {
                        store.selectedID = nil
                        model.collapse(force: true)
                    },
                    onBack: {
                        withAnimation(Theme.quickSpring) { store.selectedID = nil }
                    }
                )
                .transition(.opacity)
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Theme.text)
        // Quick settings, drawn in-panel. A click anywhere else dismisses it, and the
        // notch is held open while it's up so it can't vanish from under the pointer.
        .overlay(alignment: .topTrailing) {
            if showQuickSettings {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { closeQuickSettings() }
                    QuickSettingsView(onClose: closeQuickSettings)
                        .padding(.top, 34)
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
        }
        .onChange(of: showQuickSettings) { _, open in
            if open { model.forceOpen() } else { model.unlockAndMaybeCollapse() }
        }
        // Keyboard navigation. Unlike ⌥1/⌥2/⌥3 (global Carbon hotkeys, see
        // HotkeyManager) these only fire once the panel has been clicked and is key —
        // they're for driving the notch you're already looking at.
        .focusable()
        .onKeyPress(.escape) {
            if showQuickSettings { closeQuickSettings() }
            else if store.selectedID != nil { store.selectedID = nil }
            else { model.collapse(force: true) }
            return .handled
        }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.return) {
            guard store.selectedID == nil, let first = highlighted ?? store.sessions.first
            else { return .ignored }
            withAnimation(Theme.quickSpring) { store.selectedID = first.id }
            return .handled
        }
    }

    /// In the list, arrows move a highlight; in a focused session they switch sessions
    /// outright, which is the same mental model as moving through the list.
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let sessions = store.sessions
        guard !sessions.isEmpty else { return .ignored }

        let currentID = store.selectedID ?? highlighted?.id
        let index = currentID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(sessions.count - 1, index + delta))

        withAnimation(Theme.quickSpring) {
            if store.selectedID != nil { store.selectedID = sessions[next].id }
            else { highlightedID = sessions[next].id }
        }
        return .handled
    }

    private var highlighted: Session? {
        highlightedID.flatMap { store.session($0) }
    }

    private func closeQuickSettings() {
        withAnimation(Theme.quickSpring) { showQuickSettings = false }
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.sessions) { session in
                    SessionRowView(store: store, session: session,
                                   highlighted: session.id == highlightedID)
                }
                if store.sessions.isEmpty {
                    EmptyStateView(usage: store.usage)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }
}

/// Top strip: 5h / 7d usage percentages + reset countdowns and window controls.
struct UsageHeaderView: View {
    @Bindable var store: SessionStore
    @Binding var showQuickSettings: Bool
    @AppStorage("muteSounds") private var muteSounds = false
    @State private var hoverSound = false
    @State private var hoverGear = false

    var body: some View {
        HStack(spacing: 10) {
            usageStat(label: "5h", pct: store.usage.fiveHourPercent, resets: store.usage.fiveHourResetsIn)
            usageStat(label: "7d", pct: store.usage.weeklyPercent, resets: store.usage.weeklyResetsIn)
            // Only on plans that have a separate Opus allowance.
            if let opus = store.usage.opusPercent {
                usageStat(label: "opus", pct: opus, resets: store.usage.opusResetsIn ?? "—")
            }

            Spacer()

            if !store.usage.isLive {
                Badge(text: "local usage", tint: Theme.dim)
            }

            // Mute / unmute alert sounds and notifications (NotificationService reads this).
            iconButton(muteSounds ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       hover: $hoverSound, tint: muteSounds ? Theme.amber : Theme.dim) {
                muteSounds.toggle()
            }

            // Quick settings panel.
            iconButton("gearshape.fill", hover: $hoverGear,
                       tint: showQuickSettings ? Theme.text : Theme.dim) {
                withAnimation(Theme.quickSpring) { showQuickSettings.toggle() }
            }
        }
    }

    private func iconButton(_ symbol: String, hover: Binding<Bool>, tint: Color,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(hover.wrappedValue ? Theme.text : tint)
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }

    private func usageStat(label: String, pct: Double, resets: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textDim)
            Text("\(Int(pct * 100))%")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(usageTint(pct))
            Text(resets).font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }

    /// Prefer the API's own severity over a local percentage threshold; fall back to the
    /// threshold when the endpoint didn't say (offline / local accounting).
    private func usageTint(_ pct: Double) -> Color {
        switch store.usage.severity {
        case "exceeded", "critical": return Theme.red
        case "warning":              return Theme.amber
        case "normal":               return Theme.green
        default:                     return pct > 0.85 ? Theme.red : Theme.green
        }
    }
}

struct EmptyStateView: View {
    let usage: UsageSnapshot
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                PixelIcon(pattern: PixelIcon.invader, color: Theme.dim, pixel: 3)
                Text("No active Claude Code sessions")
                    .font(Theme.caption).foregroundStyle(Theme.dim)
                Text("Start `claude` in a terminal to see it here")
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
            UsageDashboardView(usage: usage)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
