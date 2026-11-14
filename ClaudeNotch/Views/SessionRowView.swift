import SwiftUI

/// One session card. Header line mirrors the screenshots: pixel marker + project ·
/// task, the "You:" prompt, current activity, and model/terminal badges. When the
/// session is blocking, the permission or question UI expands inline below.
struct SessionRowView: View {
    @Bindable var store: SessionStore
    let session: Session
    /// Keyboard highlight (arrow keys), separate from pointer hover.
    var highlighted: Bool = false
    /// Shared with the focused view, so the name and the critter fly into its header.
    var morph: Namespace.ID? = nil
    @State private var hovering = false
    @AppStorage("compactMode") private var compactMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Compact status line; full permission/question/detail live in the focused view.
            if session.pendingPermission != nil {
                needsYouLine(icon: "exclamationmark.triangle.fill", text: L(.permissionNeeded), tint: Theme.amber)
            } else if session.pendingQuestion != nil {
                needsYouLine(icon: "bubble.left.fill", text: L(.questionWaiting), tint: Theme.amber)
            } else if let completion = session.completion {
                needsYouLine(icon: completion.succeeded ? "checkmark.seal.fill" : "exclamationmark.octagon.fill",
                             text: completion.succeeded ? L(.taskCompletedShort) : L(.errorTitle),
                             tint: completion.succeeded ? Theme.green : Theme.red)
            } else {
                activityLine
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.Motion.quick) { store.selectedID = session.id }
        }
        .onHover { hovering = $0 }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(hovering || highlighted ? Theme.surfaceHi : Theme.surface)
                .overlay(alignment: .top) {
                    // A hairline along the top edge reads as a raised surface.
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .strokeBorder(borderTint, lineWidth: borderWidth)
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.white.opacity(0.06), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 12)
                                .allowsHitTesting(false)
                                .mask(RoundedRectangle(cornerRadius: Theme.rowCorner,
                                                       style: .continuous))
                        }
                }
        )
        // One flash when this session starts needing you — enough to catch the eye
        // without turning into a strobe that has to be looked away from.
        .keyframeAnimator(initialValue: 0.0, trigger: session.status) { view, flash in
            view.overlay(
                RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                    .strokeBorder(Theme.amber, lineWidth: 1.5)
                    .opacity(flash)
                    .allowsHitTesting(false)
            )
        } keyframes: { _ in
            if session.status == .waiting && Theme.Motion.loopsAllowed {
                CubicKeyframe(0.9, duration: 0.12)
                CubicKeyframe(0.0, duration: 0.55)
            } else {
                LinearKeyframe(0.0, duration: 0.01)
            }
        }
        .offset(y: hovering ? -1 : 0)
        .animation(Theme.Motion.quick, value: hovering)
        .animation(Theme.Motion.quick, value: highlighted)
        .animation(Theme.Motion.quick, value: session.status)
    }

    private var borderTint: Color {
        // Neutral rather than blue: a blue outline reads as a system focus ring.
        if highlighted { return Theme.text.opacity(0.35) }
        return session.status == .waiting ? Theme.amber.opacity(0.5) : Theme.stroke
    }

    private var borderWidth: CGFloat {
        highlighted || session.status == .waiting ? 1 : 0.5
    }

    private func needsYouLine(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint)
            Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(tint)
            Spacer()
            Text(L(.tapToOpen)).font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                PixelCreature(art: session.creatureArt,
                              tint: session.status.creatureTint,
                              height: 20,
                              motion: .forStatus(session.status, activity: session.activity),
                          pace: PixelCreature.pace(for: session.activity, working: 1),
                          event: store.event(for: session.id),
                          activity: session.activity)
                    .morphing("critter-\(session.id)", in: morph)
                statusGlyph
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                // Claude Code's own session title, not the last prompt.
                Text(session.displayName)
                    .font(Theme.title)
                    .lineLimit(1)
                    .morphing("title-\(session.id)", in: morph)
                // Compact mode keeps the title and drops the supporting lines.
                if !compactMode {
                    Text(session.locationLine)
                        .font(Theme.micro).foregroundStyle(Theme.dim)
                        .lineLimit(1)
                    if !session.task.isEmpty {
                        Text(L(.youSaid, session.task))
                            .font(Theme.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    AgentBadges(session: session)
                    if !session.subagents.isEmpty {
                        Badge(text: "⧉ " + Lcount(.subagentOne, .subagentMany, session.subagents.count),
                              tint: Theme.violet)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if !session.modelDisplay.isEmpty {
                        Badge(text: session.modelDisplay, tint: Theme.textDim)
                    }
                    if let t = session.terminalApp {
                        Badge(text: t, tint: Theme.textDim)
                    }
                }
                // Driven by the system clock, not by a redraw: the old computed string
                // only updated when something else in the row changed, so it sat frozen.
                HStack(spacing: 6) {
                    if session.tokens.main > 0 {
                        Text(L(.tokensShort, Lcompact(session.tokens.main)))
                            .contentTransition(.numericText(value: Double(session.tokens.main)))
                            .animation(Theme.Motion.value, value: session.tokens.main)
                            .help(tokenDetail)
                    }
                    Text(session.startedAt, style: .timer)
                        .monospacedDigit()
                }
                .font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    private var statusGlyph: some View {
        Group {
            if session.status == .working {
                WorkingBars(color: session.status.color, activity: session.activity)
            } else {
                Image(systemName: session.activity.sfSymbol)
                    .font(.system(size: 9))
                    .foregroundStyle(session.status.color)
            }
        }
    }

    // MARK: Activity line

    private var activityLine: some View {
        HStack(spacing: 6) {
            if let tool = session.currentTool {
                Text(tool)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.blue)
            }
            Text(session.activityDetail.isEmpty ? session.activity.verb : session.activityDetail)
                .font(Theme.caption).foregroundStyle(Theme.textDim)
                .lineLimit(1)
            Spacer()
            if session.filesAdded > 0 || session.filesRemoved > 0 {
                Text("+\(session.filesAdded)").font(Theme.micro).foregroundStyle(Theme.green)
                    .contentTransition(.numericText(value: Double(session.filesAdded)))
                Text("-\(session.filesRemoved)").font(Theme.micro).foregroundStyle(Theme.red)
                    .contentTransition(.numericText(value: Double(session.filesRemoved)))
            }
        }
        .animation(Theme.Motion.value, value: session.filesAdded)
        .animation(Theme.Motion.value, value: session.filesRemoved)
    }
}

extension SessionRowView {
    /// Tooltip splitting the headline token figure into its parts.
    var tokenDetail: String {
        let t = session.tokens
        return L(.tokenDetail, Lcompact(t.input), Lcompact(t.output), Lcompact(t.cache))
    }
}

extension View {
    /// `matchedGeometryEffect` when a namespace is supplied, nothing otherwise — the row
    /// is also drawn in places with no focused view to fly to.
    @ViewBuilder
    func morphing(_ id: String, in ns: Namespace.ID?) -> some View {
        if let ns { matchedGeometryEffect(id: id, in: ns) } else { self }
    }
}

/// Which agent runs the session — and, for Gemini work Claude handed over through
/// gemini-mcp, a "from Claude" chip so it isn't mistaken for a terminal you opened.
struct AgentBadges: View {
    let session: Session

    var body: some View {
        switch session.agent {
        case .claude:
            Badge(text: "Claude", tint: Color.forToken("claude"))
        case .gemini:
            Badge(text: "Gemini", tint: Theme.blue)
            if session.delegatedJob != nil {
                Badge(text: L(.delegatedBadge), tint: Color.forToken("claude"))
                    .help(L(.delegatedHelp))
            }
        }
    }
}

extension Session {
    /// The pixel creature standing in for this session's agent.
    var creatureArt: PixelCreature.Art { agent == .gemini ? .gemini : .claude }
}
