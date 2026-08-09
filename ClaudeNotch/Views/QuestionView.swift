import SwiftUI

/// Inline interactive question: header + prompt, then numbered choices with ⌥1/⌥2/⌥3
/// shortcut hints, matching the reference screenshot. Selecting a choice resolves it.
struct QuestionView: View {
    @Bindable var store: SessionStore
    let session: Session
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.amber)
                Text(L(.questionTitle)).font(Theme.title)
            }
            HStack(spacing: 4) {
                if let h = question.header {
                    Text("[\(h)]").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.amber)
                }
                Text(question.prompt).font(Theme.caption).foregroundStyle(Theme.text)
            }

            VStack(spacing: 6) {
                ForEach(question.choices) { choice in
                    choiceRow(choice)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.ink.opacity(0.6))
        )
    }

    private func choiceRow(_ choice: Question.Choice) -> some View {
        ChoiceButton(choice: choice) { resolve(choice) }
    }

    private func resolve(_ choice: Question.Choice) {
        // Routed to the coordinator, which sends the answer back to Claude Code.
        withAnimation(Theme.Motion.quick) {
            store.onQuestionAnswer?(session.id, choice.index)
        }
    }
}

struct ChoiceButton: View {
    let choice: Question.Choice
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(choice.index)")
                    .font(Theme.caption.weight(.bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.amber))
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.label).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.text)
                    if let d = choice.detail {
                        Text(d).font(Theme.micro).foregroundStyle(Theme.textDim)
                    }
                }
                Spacer()
                Text("⌥\(choice.index)").font(Theme.micro).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.amber.opacity(0.18) : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.amber.opacity(hovering ? 0.5 : 0.15), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
