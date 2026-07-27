import SwiftUI

/// One session card. Header line mirrors the screenshots: pixel marker + project ·
/// task, the "You:" prompt, current activity, and model/terminal badges. When the
/// session is blocking, the permission or question UI expands inline below.
struct SessionRowView: View {
    @Bindable var store: SessionStore
    let session: Session
    /// Keyboard highlight (arrow keys), separate from pointer hover.
    var highlighted: Bool = false
    @State private var hovering = false
    @AppStorage("compactMode") private var compactMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Compact status line; full permission/question/detail live in the focused view.
            if session.pendingPermission != nil {
                needsYouLine(icon: "exclamationmark.triangle.fill", text: "Permission needed", tint: Theme.amber)
            } else if session.pendingQuestion != nil {
                needsYouLine(icon: "bubble.left.fill", text: "Question waiting", tint: Theme.amber)
            } else if let completion = session.completion {
                needsYouLine(icon: completion.succeeded ? "checkmark.seal.fill" : "exclamationmark.octagon.fill",
                             text: completion.succeeded ? "Task completed" : "Error",
                             tint: completion.succeeded ? Theme.green : Theme.red)
            } else {
                activityLine
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.quickSpring) { store.selectedID = session.id }
        }
        .onHover { hovering = $0 }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(hovering || highlighted ? Theme.surfaceHi : Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .strokeBorder(borderTint, lineWidth: borderWidth)
                )
        )
        .animation(Theme.quickSpring, value: hovering)
        .animation(Theme.quickSpring, value: highlighted)
        .animation(Theme.quickSpring, value: session.status)
    }

    private var borderTint: Color {
        if highlighted { return Theme.blue.opacity(0.8) }
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
            Text("tap to open").font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                PixelCreature(art: .claude,
                              tint: session.status.creatureTint,
                              height: 20,
                              motion: .forStatus(session.status, activity: session.activity))
                statusGlyph
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                // Claude Code's own session title, not the last prompt.
                Text(session.displayName)
                    .font(Theme.title)
                    .lineLimit(1)
                // Compact mode keeps the title and drops the supporting lines.
                if !compactMode {
                    Text(session.locationLine)
                        .font(Theme.micro).foregroundStyle(Theme.dim)
                        .lineLimit(1)
                    if !session.task.isEmpty {
                        Text("You: \(session.task)")
                            .font(Theme.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Badge(text: "Claude", tint: Color.forToken("claude"))
                    Badge(text: session.modelDisplay, tint: Theme.textDim)
                    if let t = session.terminalApp {
                        Badge(text: t, tint: Theme.textDim)
                    }
                }
                Text(elapsedText).font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    private var statusGlyph: some View {
        Group {
            if session.status == .working {
                WorkingBars(color: session.status.color)
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
                Text("-\(session.filesRemoved)").font(Theme.micro).foregroundStyle(Theme.red)
            }
        }
    }

    private var elapsedText: String {
        let t = Int(session.elapsed)
        let m = t / 60, s = t % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
