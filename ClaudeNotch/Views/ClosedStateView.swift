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
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)

            // Gap that sits under the physical camera notch (matches its real width).
            Color.clear.frame(width: notchWidth)

            rightCluster
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(Theme.text)
    }

    private var leftCluster: some View {
        HStack(spacing: 6) {
            // A pixel marker per active session (max 3 shown), tinted by status.
            HStack(spacing: 3) {
                ForEach(store.sessions.prefix(3)) { s in
                    PixelIcon(pattern: PixelIcon.crab, color: s.status.color, pixel: 1.6)
                }
            }
            if store.aggregateStatus == .working {
                WorkingBars(color: Theme.green)
            }
            Text(statusWord)
                .font(Theme.caption)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
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
