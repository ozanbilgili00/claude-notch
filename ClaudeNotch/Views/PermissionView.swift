import SwiftUI

/// Inline permission request: title + risk, a diff (Edit/Write) or command (Bash),
/// then Deny / Allow Once / Always Allow. Choosing a button resolves the request.
struct PermissionView: View {
    @Bindable var store: SessionStore
    let session: Session
    let request: PermissionRequest

    /// Flipped once the diff appears, which drives its line-by-line reveal.
    @State private var diffRevealed = false

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
            Text(request.titleKey.map { L($0) } ?? request.toolName).font(Theme.title)
            if let path = request.filePath {
                Text(path).font(Theme.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            Badge(text: request.risk.displayName, tint: request.risk.color)
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
            // Lines arrive one after another rather than all at once, so the moment a
            // diff lands is legible instead of a block of text appearing from nowhere.
            ForEach(Array(request.diff.enumerated()), id: \.element.id) { index, line in
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
                .opacity(diffRevealed ? 1 : 0)
                .offset(x: diffRevealed ? 0 : -4)
                .animation(Theme.Motion.quick.delay(Double(index) * 0.015), value: diffRevealed)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .onAppear { diffRevealed = true }
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
            NotchButton(title: L(.deny), tint: Theme.textDim, filled: false, hint: "⌥N") {
                resolve(.deny)
            }
            NotchButton(title: L(.allowOnce), tint: Theme.text, filled: true, hint: "⌥Y") {
                resolve(.allowOnce)
            }
            NotchButton(title: L(.alwaysAllow), tint: Theme.green, filled: false, hint: "⌥⇧Y") {
                resolve(.alwaysAllow)
            }
        }
    }

    private func resolve(_ decision: PermissionDecision) {
        // Routed to the coordinator, which sends the decision back to the hook and
        // resumes the blocked Claude Code tool call.
        withAnimation(Theme.Motion.quick) {
            store.onPermissionDecision?(session.id, decision)
        }
    }
}

/// Small pill button matching the retro-terminal look.
struct NotchButton: View {
    let title: String
    var tint: Color = Theme.text
    var filled: Bool = false
    /// Keyboard shortcut shown faintly after the title, e.g. "⌥Y".
    var hint: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Theme.caption.weight(.medium))
                if let hint {
                    Text(hint).font(Theme.micro).opacity(0.55)
                }
            }
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
