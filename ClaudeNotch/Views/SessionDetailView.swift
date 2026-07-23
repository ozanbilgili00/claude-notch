import SwiftUI

/// Expanded detail for a selected session: meta, live log preview, timeline, and the
/// action buttons from the spec (Open Terminal, Open Project, Logs, Copy).
struct SessionDetailView: View {
    let session: Session
    @Binding var showFullLog: Bool
    @State private var promptText = ""
    @State private var sendHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metaRow
            if !session.logTail.isEmpty {
                LogPreview(lines: Array(session.logTail.suffix(6)))
            }
            if !session.timeline.isEmpty {
                TimelineStrip(entries: Array(session.timeline.suffix(6)))
            }
            promptInput
            buttons
        }
        .padding(.top, 4)
    }

    // MARK: Prompt input — type here, it goes straight to the session's terminal.

    private var promptInput: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green)
                TextField("Send a prompt to this session…", text: $promptText)
                    .textFieldStyle(.plain)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.text)
                    .onSubmit(sendPrompt)
                Button(action: sendPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(promptText.isEmpty ? Theme.dim : Theme.green)
                }
                .buttonStyle(.plain)
                .disabled(promptText.isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, lineWidth: 0.5)))
            if let sendHint {
                Text(sendHint).font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    private func sendPrompt() {
        let text = promptText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        promptText = ""
        let tty = session.tty, cwd = session.cwd
        Task.detached {
            let result = TerminalBridge.send(prompt: text, tty: tty, cwd: cwd)
            await MainActor.run {
                switch result {
                case .sent: sendHint = nil
                case .focusedAndCopied: sendHint = "Terminal doesn't support direct send — prompt copied, paste it in."
                case .failed: sendHint = "Couldn't reach the terminal."
                }
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            if let b = session.branch { metaItem("branch", b, Theme.violet) }
            metaItem("model", session.modelDisplay, Theme.blue)
            metaItem("tokens", format(session.sessionTokens), Theme.textDim)
            Spacer()
            if session.filesAdded > 0 || session.filesRemoved > 0 {
                Text("+\(session.filesAdded)").font(Theme.micro).foregroundStyle(Theme.green)
                Text("-\(session.filesRemoved)").font(Theme.micro).foregroundStyle(Theme.red)
            }
        }
    }

    private func metaItem(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.micro).foregroundStyle(Theme.dim)
            Text(value).font(Theme.micro.weight(.medium)).foregroundStyle(tint).lineLimit(1)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            NotchButton(title: "Focus Terminal", tint: Theme.text) {
                let tty = session.tty, cwd = session.cwd
                Task.detached { TerminalBridge.focus(tty: tty, cwd: cwd) }
            }
            NotchButton(title: "Project", tint: Theme.text) {
                SessionActions.openProject(cwd: session.cwd)
            }
            NotchButton(title: showFullLog ? "Hide History" : "History", tint: Theme.blue) {
                withAnimation(Theme.quickSpring) { showFullLog.toggle() }
            }
        }
    }

    private func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// A compact syntax-tinted log preview.
struct LogPreview: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Theme.micro)
                    .foregroundStyle(color(for: line))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4)))
    }

    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("fail") { return Theme.red }
        if l.contains("pass") || l.contains("✓") || l.contains("success") { return Theme.green }
        if line.hasPrefix("$") || line.hasPrefix("→") { return Theme.blue }
        return Theme.textDim
    }
}

/// A vertical timeline of recent activity.
struct TimelineStrip: View {
    let entries: [TimelineEntry]
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Text(Self.fmt.string(from: entry.time))
                        .font(Theme.micro).foregroundStyle(Theme.dim)
                        .frame(width: 34, alignment: .leading)
                    Circle().fill(Theme.textDim).frame(width: 4, height: 4)
                    Text(entry.text).font(Theme.micro).foregroundStyle(Theme.textDim).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
