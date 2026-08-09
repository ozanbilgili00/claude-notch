import SwiftUI
import AppKit

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
    /// Flipped once the list appears, which drives the staggered reveal.
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            UsageHeaderView(store: store, showQuickSettings: $showQuickSettings, ns: ns,
                            notchWidth: model.notch.notchSize.width)
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
                        withAnimation(Theme.Motion.quick) { store.selectedID = nil }
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
        // Focusable only so the arrow keys work; macOS's blue focus ring around the
        // whole panel is not part of the design.
        .focusEffectDisabled()
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
            withAnimation(Theme.Motion.quick) { store.selectedID = first.id }
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

        withAnimation(Theme.Motion.quick) {
            if store.selectedID != nil { store.selectedID = sessions[next].id }
            else { highlightedID = sessions[next].id }
        }
        return .handled
    }

    private var highlighted: Session? {
        highlightedID.flatMap { store.session($0) }
    }

    private func closeQuickSettings() {
        withAnimation(Theme.Motion.quick) { showQuickSettings = false }
    }

    /// Rows settle in one after another as the panel opens. The delay is tiny — it reads
    /// as the list unfolding rather than as a queue of separate animations.
    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionRowView(store: store, session: session,
                                   highlighted: session.id == highlightedID)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 6)
                        .animation(Theme.Motion.quick.delay(Double(index) * Theme.Motion.stagger),
                                   value: revealed)
                        .transition(.blurReplace)
                }
                if store.sessions.isEmpty {
                    EmptyStateView(usage: store.usage)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .onAppear { revealed = true }
    }
}

/// Top strip: 5h / 7d usage percentages + reset countdowns and window controls.
struct UsageHeaderView: View {
    @Bindable var store: SessionStore
    @Binding var showQuickSettings: Bool
    var ns: Namespace.ID
    /// Width of the physical (or synthesized) notch. The window is always centered on
    /// it, so a plain flexible-spacer row lets whichever stat lands near the middle end
    /// up rendered behind the camera housing — invisible, not just cramped. A fixed gap
    /// here, the same trick the closed pill already uses, keeps everything on either side.
    var notchWidth: CGFloat
    @AppStorage("muteSounds") private var muteSounds = false
    @State private var hoverSound = false
    @State private var hoverGear = false
    @State private var hoverQuit = false

    var body: some View {
        HStack(spacing: 0) {
            leftGroup.frame(maxWidth: .infinity, alignment: .leading)
            // Height pinned to 1: a bare `Color` is flexible in *both* axes, so left to
            // itself this spacer stretched the header vertically and the VStack handed it
            // half the panel — the row of text ended up floating in a large empty band.
            Color.clear.frame(width: notchWidth, height: 1)
            rightGroup.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var leftGroup: some View {
        HStack(spacing: 10) {
            // The mascot and status word carry over from the closed pill: they are the
            // same elements, matched across the morph, so the panel grows *around* them
            // rather than replacing them.
            HStack(spacing: 6) {
                PixelCreature(art: .turtle,
                              tint: store.aggregateStatus.creatureTint,
                              height: 18,
                              motion: .forStatus(store.aggregateStatus,
                                                 activity: store.focusedSession?.activity ?? .idle))
                    .matchedGeometryEffect(id: MorphID.creature, in: ns)
                Text(store.statusWord)
                    .font(Theme.caption).foregroundStyle(Theme.textDim)
                    .lineLimit(1).fixedSize()
                    .matchedGeometryEffect(id: MorphID.status, in: ns)
            }

            Divider().frame(height: 12).overlay(Theme.stroke)

            usageStat(label: L(.usageFiveHour), pct: store.usage.fiveHourPercent, resets: store.usage.fiveHourResetsIn)
                .matchedGeometryEffect(id: MorphID.usage, in: ns)
        }
    }

    private var rightGroup: some View {
        HStack(spacing: 10) {
            // The weekly windows live on this side because the left half only reaches as
            // far as the camera housing; crowding all three stats in there is what pushed
            // the 7-day figure under the notch in the first place.
            usageStat(label: L(.usageWeekly), pct: store.usage.weeklyPercent, resets: store.usage.weeklyResetsIn)
            // Only on plans that have a separate Opus allowance.
            if let opus = store.usage.opusPercent {
                usageStat(label: "opus", pct: opus, resets: store.usage.opusResetsIn)
            }

            let n = store.sessions.count
            Text(L(.sessionCountShort, n))
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .contentTransition(.numericText(value: Double(n)))
                .animation(Theme.Motion.value, value: n)
                .matchedGeometryEffect(id: MorphID.count, in: ns)

            if !store.usage.isLive {
                Badge(text: L(.usageLocal), tint: Theme.dim)
            }

            // Mute / unmute alert sounds and notifications (NotificationService reads this).
            iconButton(muteSounds ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       hover: $hoverSound, tint: muteSounds ? Theme.amber : Theme.dim) {
                muteSounds.toggle()
            }

            // Quick settings panel.
            iconButton("gearshape.fill", hover: $hoverGear,
                       tint: showQuickSettings ? Theme.text : Theme.dim) {
                withAnimation(Theme.Motion.quick) { showQuickSettings.toggle() }
            }

            // Quits the app, not just the panel — the notch goes away until it is
            // launched again. Turns red under the pointer so it doesn't read as a
            // dismiss button sitting one icon away from the gear.
            iconButton("power", hover: $hoverQuit, tint: Theme.dim, hoverTint: Theme.red) {
                NSApp.terminate(nil)
            }
        }
    }

    private func iconButton(_ symbol: String, hover: Binding<Bool>, tint: Color,
                            hoverTint: Color = Theme.text,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(hover.wrappedValue ? hoverTint : tint)
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }

    private func usageStat(label: String, pct: Double, resets: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textDim)
            Text(L10n.percent(Int(pct * 100), Localization.shared.language))
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(usageTint(pct))
                .contentTransition(.numericText(value: pct))
            // Without an explicit limit these wrap to two lines the moment the header's
            // left half gets tight (e.g. on the real notch, now that the mascot actually
            // takes up its real width — see the matchedGeometryEffect fix in
            // PixelCreature). A single overflowing line reads better than a wrapped one.
            Text(resets).font(Theme.micro).foregroundStyle(Theme.dim)
                .lineLimit(1).fixedSize()
        }
        .animation(Theme.Motion.value, value: pct)
        .lineLimit(1)
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
                Text(L(.emptyTitle))
                    .font(Theme.caption).foregroundStyle(Theme.dim)
                Text(L(.emptyHint))
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
            UsageDashboardView(usage: usage)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
