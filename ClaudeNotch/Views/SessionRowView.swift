import SwiftUI

/// One session card. Header line mirrors the screenshots: pixel marker + project ·
/// task, the "You:" prompt, current activity, and model/terminal badges. When the
/// session is blocking, the permission or question UI expands inline below.
struct SessionRowView: View {
    @Bindable var store: SessionStore
    let session: Session
    @State private var showFullLog = false

    private var isSelected: Bool { store.selectedID == session.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Theme.quickSpring) {
                        store.selectedID = isSelected ? nil : session.id
                    }
                }
            if let perm = session.pendingPermission {
                PermissionView(store: store, session: session, request: perm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let q = session.pendingQuestion {
                QuestionView(store: store, session: session, question: q)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let completion = session.completion {
                CompletionView(store: store, session: session, completion: completion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                activityLine
                if isSelected {
                    SessionDetailView(session: session, showFullLog: $showFullLog)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    if showFullLog {
                        LogViewer(lines: session.logTail)
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .strokeBorder(borderTint, lineWidth: session.status == .waiting ? 1 : 0.5)
                )
        )
        .animation(Theme.quickSpring, value: session.pendingPermission?.id)
        .animation(Theme.quickSpring, value: session.pendingQuestion?.id)
    }

    private var borderTint: Color {
        session.status == .waiting ? Theme.amber.opacity(0.5) : Theme.stroke
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                PixelIcon(pattern: PixelIcon.crab, color: session.status.color, pixel: 2)
                statusGlyph
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.projectName).font(Theme.title)
                    Text("·").foregroundStyle(Theme.dim)
                    Text(session.task)
                        .font(Theme.body).foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                Text("You: \(session.task)")
                    .font(Theme.caption).foregroundStyle(Theme.textDim)
                    .lineLimit(1)
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
