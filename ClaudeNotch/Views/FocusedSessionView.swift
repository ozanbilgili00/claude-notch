import SwiftUI

/// Full-panel view for a single selected session: header + Done, the pending
/// permission/question/completion if any, otherwise a Conversation / Log tab pair with
/// a prompt box, and a "Show all sessions" button back to the list.
struct FocusedSessionView: View {
    @Bindable var store: SessionStore
    let session: Session
    var onDone: () -> Void
    var onBack: () -> Void

    enum Tab { case conversation, log }
    @State private var tab: Tab = .conversation
    @State private var promptText = ""
    @State private var sendHint: String?
    @State private var promptExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            Group {
                if let perm = session.pendingPermission {
                    scroll { PermissionView(store: store, session: session, request: perm) }
                } else if let q = session.pendingQuestion {
                    scroll { QuestionView(store: store, session: session, question: q) }
                } else if let completion = session.completion {
                    scroll { CompletionView(store: store, session: session, completion: completion) }
                } else {
                    mainContent
                }
            }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { content().padding(12) }.scrollIndicators(.hidden)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            PixelCreature(art: .claude,
                          tint: session.status.creatureTint,
                          height: 22,
                          motion: .forStatus(session.status, activity: session.activity))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName).font(Theme.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.locationLine)
                        .font(Theme.micro).foregroundStyle(Theme.dim).lineLimit(1)
                    // System-driven, so it keeps counting without anything redrawing.
                    Text(session.startedAt, style: .timer)
                        .font(Theme.micro).foregroundStyle(Theme.dim).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Badge(text: "Claude", tint: Color.forToken("claude"))
                Badge(text: session.modelDisplay, tint: Theme.textDim)
            }
            Button(L(.done), action: onDone)
                .buttonStyle(.plain)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    // MARK: Main (tabs + prompt)

    private var mainContent: some View {
        VStack(spacing: 8) {
            tabBar
            lastPromptStrip
            Group {
                if tab == .conversation {
                    ConversationView(turns: session.conversation, status: session.status)
                } else {
                    LogViewer(lines: session.logTail)
                }
            }
            .frame(maxHeight: .infinity)
            promptInput
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(L(.tabConversation), .conversation)
            tabButton(L(.tabLog), .log)
            Spacer()
        }
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { withAnimation(Theme.Motion.quick) { tab = value } } label: {
            Text(title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(tab == value ? Theme.text : Theme.dim)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tab == value ? Theme.surfaceHi : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Last prompt (pinned)

    /// The most recent thing the user said, held just under the tabs so it stays visible
    /// however far the conversation is scrolled. Collapsed to one line; tap to expand.
    @ViewBuilder
    private var lastPromptStrip: some View {
        if let text = lastUserPrompt {
            VStack(spacing: 0) {
                Divider().overlay(Theme.stroke)
                HStack(alignment: .top, spacing: 6) {
                    Text(L(.youPrefix))
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(text)
                        .font(Theme.caption).foregroundStyle(Theme.text)
                        .lineLimit(promptExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: promptExpanded)
                    Spacer(minLength: 4)
                    Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Theme.Motion.quick) { promptExpanded.toggle() }
                }
                Divider().overlay(Theme.stroke)
            }
        }
    }

    /// Prefer the full text from the transcript; fall back to the session's short task.
    private var lastUserPrompt: String? {
        if let turn = session.conversation.last(where: { $0.role == .user }) { return turn.text }
        return session.task.isEmpty ? nil : session.task
    }

    // MARK: Prompt input

    private var promptInput: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                TextField(L(.promptPlaceholder), text: $promptText)
                    .textFieldStyle(.plain).font(Theme.caption).foregroundStyle(Theme.text)
                    .onSubmit(sendPrompt)
                Button(action: sendPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(promptText.isEmpty ? Theme.dim : Theme.accent)
                }
                .buttonStyle(.plain).disabled(promptText.isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, lineWidth: 0.5)))
            if let sendHint {
                Text(sendHint).font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        Button(action: onBack) {
            Text(Lcount(.showAllSessionsOne, .showAllSessionsMany, store.sessions.count))
                .font(Theme.caption)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: Actions

    private func sendPrompt() {
        let text = promptText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        promptText = ""
        let tty = session.tty, cwd = session.cwd, app = session.terminalApp
        Task.detached {
            let result = TerminalBridge.send(prompt: text, tty: tty, cwd: cwd, app: app)
            await MainActor.run {
                switch result {
                case .sent:
                    sendHint = nil
                case .focusedAndCopied(let app):
                    // Only Terminal.app and iTerm2 accept scripted input; say which one
                    // can't rather than blaming "the terminal" in general.
                    let name = app ?? L(.thisTerminal)
                    sendHint = L(.terminalNoScriptedInput, name)
                case .failed:
                    sendHint = L(.terminalUnreachable)
                }
            }
        }
    }
}

/// Renders conversation turns with light markdown (bullets, bold, inline code).
struct ConversationView: View {
    let turns: [ConversationTurn]
    let status: SessionStatus

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                    if turns.isEmpty {
                        Text(L(.noConversation))
                            .font(Theme.caption).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.visible)
            .onChange(of: turns.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: ConversationTurn) -> some View {
        if turn.role == .user {
            HStack(alignment: .top, spacing: 6) {
                Text(L(.youPrefix)).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(turn.text).font(Theme.caption).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(turn.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    lineView(String(line))
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(Theme.dim)
                styled(String(trimmed.dropFirst(2)))
            }
            .padding(.leading, 4)
        } else {
            styled(raw)
        }
    }

    private func styled(_ s: String) -> some View {
        Text(attributed(s))
            .font(Theme.caption)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
