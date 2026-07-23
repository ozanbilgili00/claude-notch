import SwiftUI

/// The "Task Completed" / "Error" screen shown inline when a turn finishes. Success
/// shows duration + files changed + tests; failure shows the error with Retry / Logs.
struct CompletionView: View {
    @Bindable var store: SessionStore
    let session: Session
    let completion: Completion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statsRow
            buttons
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill((completion.succeeded ? Theme.green : Theme.red).opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .strokeBorder((completion.succeeded ? Theme.green : Theme.red).opacity(0.35),
                                      lineWidth: 0.5)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: completion.succeeded ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .foregroundStyle(completion.succeeded ? Theme.green : Theme.red)
                .font(.system(size: 12))
                .symbolEffect(.bounce, value: completion.succeeded)
            Text(completion.succeeded ? "Task Completed" : "Error")
                .font(Theme.title)
            Spacer()
            Text(durationText).font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            if !completion.summary.isEmpty {
                Text(completion.summary).font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(2)
            }
            Spacer(minLength: 0)
            if completion.filesAdded > 0 || completion.filesRemoved > 0 {
                Text("+\(completion.filesAdded)").font(Theme.micro).foregroundStyle(Theme.green)
                Text("-\(completion.filesRemoved)").font(Theme.micro).foregroundStyle(Theme.red)
            }
            if let tests = completion.testsStatus {
                Badge(text: tests, tint: tests.contains("pass") ? Theme.green : Theme.red)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if completion.succeeded {
                NotchButton(title: "Open Terminal", tint: Theme.text) {
                    SessionActions.openTerminal(cwd: session.cwd)
                }
            } else {
                NotchButton(title: "Open Terminal", tint: Theme.text) {
                    SessionActions.openTerminal(cwd: session.cwd)
                }
            }
            NotchButton(title: "Dismiss", tint: Theme.textDim) {
                withAnimation(Theme.quickSpring) {
                    store.update(session.id) { $0.completion = nil }
                }
            }
        }
    }

    private var durationText: String {
        let t = Int(completion.duration)
        let m = t / 60, s = t % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
