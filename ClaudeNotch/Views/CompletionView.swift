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
            Text(completion.succeeded ? L(.taskCompleted) : L(.errorTitle))
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
            if let passed = completion.testsPassed {
                Badge(text: passed ? L(.testsPassing) : L(.testsFailing),
                      tint: passed ? Theme.green : Theme.red)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            // Success and failure offered the same button through two identical branches.
            NotchButton(title: L(.openTerminal), tint: Theme.text) {
                SessionActions.openTerminal(cwd: session.cwd)
            }
            NotchButton(title: L(.dismiss), tint: Theme.textDim) {
                withAnimation(Theme.Motion.quick) {
                    store.update(session.id) { $0.completion = nil }
                }
            }
        }
    }

    private var durationText: String {
        let t = Int(completion.duration)
        let m = t / 60, s = t % 60
        return m > 0 ? "\(m)\(L(.unitMinute)) \(s)\(L(.unitSecond))" : "\(s)\(L(.unitSecond))"
    }
}
