import SwiftUI
import AppKit

/// The full panel: a usage header, then a stack of session cards. A card that is
/// blocking (permission or question) expands inline to show the diff / choices.
struct ExpandedView: View {
    @Bindable var store: SessionStore
    @Bindable var spotify: SpotifyService
    @Bindable var lyrics: LyricsService
    @Bindable var artwork: ArtworkLoader
    @Bindable var shelf: ShelfStore
    @Bindable var web: SpotifyWebAPI
    @Bindable var audio: AudioService
    var ns: Namespace.ID

    /// Width of the gap to leave in the middle of the header. The notch layout needs it so
    /// nothing renders behind the camera housing; the edge layout has no housing to avoid
    /// and passes 0.
    var headerGap: CGFloat
    /// Hold the panel open (true) or release the hold (false). Whatever is presenting this
    /// view owns what "open" means — the notch hanging from the menu bar and the dock on
    /// the right edge answer it differently.
    var holdOpen: (Bool) -> Void
    /// Close the panel outright: Done, Escape, the last session dismissed.
    var close: () -> Void

    enum Tab: Int, Comparable {
        case sessions, music, shelf, mixer, settings
        static func < (a: Tab, b: Tab) -> Bool { a.rawValue < b.rawValue }
    }
    @State private var tab: Tab = .sessions
    /// Which way the last tab change went, so content slides in from the side of the tab
    /// that was picked. Set before `tab` changes: a transition is chosen at that moment.
    @State private var tabForward = true
    @Namespace private var tabNS
    @Namespace private var rowMorph
    /// Drives the open sequence: header, then tabs, then content, a beat apart.
    @State private var appeared = false

    /// Every tab change goes through here, so the direction is always right.
    private func select(_ new: Tab) {
        guard new != tab else { return }
        tabForward = new > tab
        withAnimation(Theme.Motion.tabSlide) { tab = new }
    }

    /// Content arrives from the side of the chosen tab and leaves towards the other.
    private var tabTransition: AnyTransition {
        let shift: CGFloat = tabForward ? 28 : -28
        return .asymmetric(
            insertion: .modifier(active: SlideFade(x: shift), identity: SlideFade(x: 0, opacity: 1)),
            removal: .modifier(active: SlideFade(x: -shift), identity: SlideFade(x: 0, opacity: 1)))
    }

    /// The cover's colour, washed across the whole panel at very low opacity.
    ///
    /// A blurred copy of the artwork would be the obvious way to do this and the wrong
    /// one: `.blur` on a panel-sized layer is a full-surface pass every frame, and this
    /// panel already animates equalizer bars and a walking creature over the top of it.
    /// A static two-stop gradient reads the same and costs nothing.
    ///
    /// It fades in and out with the tab rather than mounting with `MusicView`, so leaving
    /// Music doesn't snap the panel back to black.
    ///
    /// Masked off at the top on purpose. The wash used to run edge to edge, which put its
    /// strongest point in the header — so the status line and the usage read-out sat on a
    /// tinted strip while the notch and menu bar right above them stayed black, and the
    /// seam between the two was the first thing the eye landed on. The top of the panel is
    /// now held at pure black through the status line and eases into the colour below it.
    @ViewBuilder
    private var musicAmbience: some View {
        let showing = tab == .music && showsMusicTab
        LinearGradient(colors: [artwork.accent.opacity(showing ? 0.18 : 0), .clear],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .mask(ambienceMask)
            .animation(Theme.Motion.value, value: artwork.accent)
            .animation(Theme.Motion.quick, value: showing)
            .allowsHitTesting(false)
    }

    /// Measured in points rather than as a fraction of the panel: the strip that has to
    /// stay black is a fixed row of text, not a proportion of whatever height the panel
    /// happens to be.
    private var ambienceMask: some View {
        VStack(spacing: 0) {
            // Down to the underside of the status word: 10pt of top padding plus the line
            // itself. Nothing is painted over this.
            Color.clear.frame(height: 30)
            // The hand-off. Long enough that there is no edge to see — the tab strip sits
            // inside it, so the colour has arrived by the time the content starts.
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 46)
            Color.black
        }
    }

    /// Keyboard highlight in the list (distinct from `store.selectedID`, which opens
    /// the focused view).
    @State private var highlightedID: String?
    /// Flipped once the list appears, which drives the staggered reveal.
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            UsageHeaderView(store: store, ns: ns, notchWidth: headerGap)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().overlay(Theme.stroke)
                .opacity(appeared ? 1 : 0)

            // The mixer is always available — it needs no other app running — so the
            // strip is always worth its ~26pt now.
            tabBar
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -4)
                .animation(Theme.Motion.quick.delay(Theme.Motion.reduced ? 0 : 0.05), value: appeared)

            if tab == .music, showsMusicTab {
                MusicView(spotify: spotify, lyrics: lyrics, artwork: artwork, web: web)
                    .transition(tabTransition)
            } else if tab == .shelf, showsShelfTab {
                ShelfView(shelf: shelf, onDragOut: holdOpenDuringDrag)
                    .transition(tabTransition)
            } else if tab == .mixer {
                MixerView(audio: audio)
                    .transition(tabTransition)
            } else if tab == .settings {
                SettingsPaneView(spotify: spotify, shelf: shelf, web: web,
                                 audio: audio, store: store)
                    .transition(tabTransition)
            } else if let id = store.selectedID, let session = store.session(id) {
                FocusedSessionView(
                    store: store, session: session,
                    onDone: {
                        store.selectedID = nil
                        close()
                    },
                    onBack: {
                        withAnimation(Theme.Motion.quick) { store.selectedID = nil }
                    },
                    morph: rowMorph
                )
                .transition(.opacity)
            } else {
                sessionList
                    .transition(tabTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The cover's wash sits behind the entire panel — header and tab strip included —
        // so it reaches every edge instead of starting at the top of the Music tab's own
        // frame and cutting off on a hard line under the tabs.
        .background(musicAmbience)
        .foregroundStyle(Theme.text)
        // Anything that needs the user outranks music: the panel is being forced open to
        // show a permission or a question, so it must not open onto the Music tab.
        .onAppear { appeared = true }
        .onChange(of: store.blockingSession?.id) { _, blocking in
            if blocking != nil { select(.sessions) }
        }
        .onChange(of: showsMusicTab) { _, available in
            if !available, tab == .music { select(.sessions) }
        }
        .onChange(of: showsShelfTab) { _, available in
            if !available, tab == .shelf { select(.sessions) }
        }
        // Dropping onto the *expanded* panel. The closed pill is handled a layer down, by
        // the window itself (see NotchPanel) — while the pill is showing, this view passes
        // clicks through and so is never offered the drag at all.
        .dropDestination(for: URL.self) { urls, _ in
            guard shelf.enabled else { return false }
            let taken = shelf.add(urls.filter(\.isFileURL))
            if taken > 0 { select(.shelf) }
            return taken > 0
        } isTargeted: { targeted in
            guard shelf.enabled, targeted else { return }
            select(.shelf)
        }
        // Keyboard navigation. Unlike ⌥1/⌥2/⌥3 (global Carbon hotkeys, see
        // HotkeyManager) these only fire once the panel has been clicked and is key —
        // they're for driving the notch you're already looking at.
        .focusable()
        // Focusable only so the arrow keys work; macOS's blue focus ring around the
        // whole panel is not part of the design.
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if tab == .settings { select(.sessions) }
            else if store.selectedID != nil { store.selectedID = nil }
            else { close() }
            return .handled
        }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        // With a permission on screen, ↩ allows once and ⌘↩ always allows — the same
        // answers ⌥Y / ⌥⇧Y give from anywhere. Esc keeps closing the panel: dismissing
        // should never double as a decision.
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard let id = store.selectedID, store.session(id)?.pendingPermission != nil
            else { return .ignored }
            let decision: PermissionDecision = press.modifiers.contains(.command) ? .alwaysAllow : .allowOnce
            withAnimation(Theme.Motion.quick) { store.onPermissionDecision?(id, decision) }
            return .handled
        }
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

    /// Spotify has to actually be running — an empty Music tab on a Mac that never opens
    /// Spotify is just a worse Sessions panel.
    private var showsMusicTab: Bool { spotify.enabled && spotify.isRunning }

    /// Unlike Music, the shelf tab shows even when it is empty: an empty shelf is exactly
    /// when you need to see where the drop target is.
    private var showsShelfTab: Bool { shelf.enabled }

    /// Dragging a file *out* of the shelf takes the pointer off the panel, which would
    /// otherwise collapse it and cancel the drag halfway. The AppKit handle reports both
    /// ends of the session, so the hold is released exactly when the drag finishes.
    private func holdOpenDuringDrag(_ dragging: Bool) {
        holdOpen(dragging)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(L(.tabSessions), .sessions)
            if showsMusicTab { tabButton(L(.tabMusic), .music) }
            if showsShelfTab { tabButton(L(.tabShelf), .shelf) }
            tabButton(L(.tabMixer), .mixer)
            tabButton(L(.tabSettings), .settings)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { select(value) } label: {
            Text(title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(tab == value ? Theme.text : Theme.dim)
                .padding(.horizontal, 10).padding(.vertical, 4)
                // One highlight that slides between tabs, rather than one per tab
                // fading in and out.
                .background {
                    if tab == value {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Theme.surfaceHi)
                            .matchedGeometryEffect(id: "tabHighlight", in: tabNS)
                    }
                }
                .animation(Theme.Motion.quick, value: tab)
        }
        .buttonStyle(.plain)
    }

    /// Rows settle in one after another as the panel opens. The delay is tiny — it reads
    /// as the list unfolding rather than as a queue of separate animations.
    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionRowView(store: store, session: session,
                                   highlighted: session.id == highlightedID, morph: rowMorph)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 6)
                        .animation(Theme.Motion.quick.delay(0.08 + Double(index) * Theme.Motion.stagger),
                                   value: revealed)
                        .transition(.blurReplace)
                }
                if store.sessions.isEmpty {
                    EmptyStateView(usage: store.usage)
                }
                DailySummaryCard(store: store)
                    .opacity(revealed ? 1 : 0)
                    .animation(Theme.Motion.quick.delay(Double(store.sessions.count) * Theme.Motion.stagger),
                               value: revealed)
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
    var ns: Namespace.ID
    /// Width of the physical (or synthesized) notch. The window is always centered on
    /// it, so a plain flexible-spacer row lets whichever stat lands near the middle end
    /// up rendered behind the camera housing — invisible, not just cramped. A fixed gap
    /// here, the same trick the closed pill already uses, keeps everything on either side.
    var notchWidth: CGFloat
    @AppStorage("muteSounds") private var muteSounds = false
    @State private var hoverSound = false
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
                                                 activity: store.focusedSession?.activity ?? .idle),
                              pace: PixelCreature.pace(for: store.focusedSession?.activity ?? .idle,
                                                       working: store.workingCount),
                              event: store.event,
                              activity: store.focusedSession?.activity ?? .idle)
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
                .help(store.usage.weekTokens > 0
                      ? L(.usageToday, Lcompact(store.usage.todayTokens)) + " · "
                        + L(.usageThisWeek, Lcompact(store.usage.weekTokens))
                      : "")
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

/// Offset plus fade, for content changing places sideways.
struct SlideFade: ViewModifier {
    var x: CGFloat
    var opacity: Double = 0
    func body(content: Content) -> some View {
        content.offset(x: Theme.Motion.reduced ? 0 : x).opacity(opacity)
    }
}

/// Content leaving the panel as it closes: it softens and draws in towards the notch
/// slightly ahead of the silhouette, so the shape seems to swallow it.
struct CloseAway: ViewModifier {
    var progress: CGFloat      // 1 = fully gone
    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .scaleEffect(Theme.Motion.reduced ? 1 : 1 - 0.04 * progress, anchor: .top)
            .blur(radius: Theme.Motion.reduced ? 0 : 6 * progress)
    }
}
