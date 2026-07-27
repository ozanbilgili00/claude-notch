import SwiftUI

/// The compact pill shown when the notch is closed: pixel-art session markers on the
/// left of the physical notch, a status word, and a mini usage readout on the right.
struct ClosedStateView: View {
    @Bindable var store: SessionStore
    var notchWidth: CGFloat
    var ns: Namespace.ID

    private var focused: Session? { store.focusedSession }

    var body: some View {
        HStack(spacing: 0) {
            leftCluster
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            // Gap that sits under the physical camera notch (matches its real width).
            Color.clear.frame(width: notchWidth)

            rightCluster
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(Theme.text)
    }

    private var leftCluster: some View {
        HStack(spacing: 6) {
            // The turtle is the notch's own mascot (sessions get Claude's critter).
            PixelCreature(art: .turtle,
                          tint: store.aggregateStatus.creatureTint,
                          height: 18,
                          motion: .forStatus(store.aggregateStatus,
                                             activity: store.focusedSession?.activity ?? .idle))
            if store.aggregateStatus == .working {
                WorkingBars(color: Theme.green)
            }
            Text(statusWord)
                .font(Theme.caption)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 6) {
            if store.usage.isLive {
                Text("5h")
                    .font(Theme.micro).foregroundStyle(Theme.dim)
                Text("\(Int(store.usage.fiveHourPercent * 100))%")
                    .font(Theme.micro).foregroundStyle(Theme.green)
            }
            let n = store.sessions.count
            Text("\(n) sess")
                .font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }

    private var statusWord: String {
        if let b = store.blockingSession {
            return b.pendingPermission != nil ? "Permission…" : "Question…"
        }
        switch store.aggregateStatus {
        case .working: return "Working…"
        case .waiting: return "Waiting…"
        case .error:   return "Error"
        case .idle:    return "Idle"
        }
    }
}
