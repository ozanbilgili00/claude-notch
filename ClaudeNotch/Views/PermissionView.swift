import SwiftUI

/// Inline permission request: title + risk, a diff (Edit/Write) or command (Bash),
/// then Deny / Allow Once / Always Allow. Choosing a button resolves the request.
struct PermissionView: View {
    @Bindable var store: SessionStore
    let session: Session
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            if !request.diff.isEmpty {
                diffView
            } else if let cmd = request.command {
                commandView(cmd)
            }
            buttons
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.ink.opacity(0.6))
        )
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(Theme.amber)
            Text(request.title).font(Theme.title)
            if let path = request.filePath {
                Text(path).font(Theme.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            Badge(text: request.risk.label, tint: request.risk.color)
        }
    }

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = request.filePath {
                HStack(spacing: 6) {
                    Text(path).font(Theme.micro).foregroundStyle(Theme.textDim)
                    let add = request.diff.filter { $0.kind == .added }.count
                    let rem = request.diff.filter { $0.kind == .removed }.count
                    Text("+\(add)").font(Theme.micro).foregroundStyle(Theme.green)
                    Text("-\(rem)").font(Theme.micro).foregroundStyle(Theme.red)
                }
                .padding(.bottom, 4)
            }
            ForEach(request.diff) { line in
                HStack(spacing: 6) {
                    Text(line.sign).font(Theme.micro).foregroundStyle(line.color).frame(width: 8)
                    Text(line.text)
                        .font(Theme.caption)
                        .foregroundStyle(line.kind == .context ? Theme.textDim : Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(line.background)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
    }

    private func commandView(_ cmd: String) -> some View {
        Text(cmd)
            .font(Theme.caption)
            .foregroundStyle(Theme.text)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            NotchButton(title: "Deny", tint: Theme.textDim, filled: false) {
                resolve(.deny)
            }
            NotchButton(title: "Allow Once", tint: Theme.text, filled: true) {
                resolve(.allowOnce)
            }
            NotchButton(title: "Always Allow", tint: Theme.green, filled: false) {
                resolve(.alwaysAllow)
            }
        }
    }

    private func resolve(_ decision: PermissionDecision) {
        // Routed to the coordinator, which sends the decision back to the hook and
        // resumes the blocked Claude Code tool call.
        withAnimation(Theme.quickSpring) {
            store.onPermissionDecision?(session.id, decision)
        }
    }
}

/// Small pill button matching the retro-terminal look.
struct NotchButton: View {
    let title: String
    var tint: Color = Theme.text
    var filled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(filled ? Color.black : tint)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(filled ? tint : (hovering ? Theme.surfaceHi : Theme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tint.opacity(filled ? 0 : 0.3), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
