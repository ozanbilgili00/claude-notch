import SwiftUI

/// The dock's status head: what the sessions are doing, visible without opening anything.
///
/// The rings answer "how much quota is left", which is not the question this app exists to
/// answer. In notch mode the closed pill is always showing the mascot, the working bars and
/// the bell; edge mode had no equivalent, so a question could sit unanswered behind a dock
/// that looked perfectly calm. This is that signal, in 34 points.
///
/// Priority runs the same way the closed pill's does: anything that needs the user outranks
/// work in flight, which outranks a turn that just landed, which outranks idle.
struct EdgeStatusHead: View {
    @Bindable var store: SessionStore
    var open: () -> Void

    private var completion: Completion? {
        // Only while nothing more urgent is happening: a finished turn is news, a pending
        // question is a request.
        store.aggregateStatus == .idle ? store.recentCompletion : nil
    }

    private var tint: Color {
        if store.aggregateStatus == .idle, let completion {
            return completion.succeeded ? Theme.green : Theme.red
        }
        return store.aggregateStatus.color
    }

    var body: some View {
        Button(action: open) {
            ZStack {
                Circle().fill(Theme.surface)
                Circle().strokeBorder(tint.opacity(0.55), lineWidth: 2)
                glyph
            }
            .frame(width: 34, height: 34)
            .frame(width: EdgeGeometry.dockWidth, height: EdgeGeometry.statusHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.statusWord)
        .animation(Theme.Motion.quick, value: store.aggregateStatus)
    }

    @ViewBuilder
    private var glyph: some View {
        switch store.aggregateStatus {
        case .working:
            WorkingBars(color: Theme.green,
                        activity: store.focusedSession?.activity ?? .shell)
        case .waiting:
            // The same bell the pill raises, pulsing for the same reason: a still glyph in
            // a strip the eye has learned to ignore is a question that goes unanswered.
            Image(systemName: "bell.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .symbolEffect(.pulse, options: .repeating, isActive: Theme.Motion.loopsAllowed)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.red)
        case .idle:
            if let completion {
                Image(systemName: completion.succeeded
                      ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(completion.succeeded ? Theme.green : Theme.red)
                    .symbolEffect(.bounce, value: completion.succeeded)
                    .transition(.scale.combined(with: .opacity))
            } else {
                PixelCreature(art: .turtle,
                              tint: nil,
                              height: 18,
                              motion: .forStatus(.idle, activity: .idle),
                              event: store.event)
            }
        }
    }
}
