import SwiftUI

/// Identifiers for the elements that exist in both the closed pill and the expanded
/// panel. They are matched across the morph so they fly between layouts instead of
/// cross-fading in place — the difference between "the notch grew" and "two views swapped".
enum MorphID {
    static let creature = "morph.creature"
    static let status   = "morph.status"
    static let usage    = "morph.usage"
    static let count    = "morph.count"
}

/// The compact pill shown when the notch is closed: the mascot and status on the left of
/// the physical notch, a mini usage readout on the right.
struct ClosedStateView: View {
    @Bindable var store: SessionStore
    /// Whether this Mac actually has a physical camera notch, vs. the synthesized pill
    /// drawn on external displays. Only the real one visually crowds the mascot.
    var isRealNotch: Bool
    var notchWidth: CGFloat
    var ns: Namespace.ID
    /// True while the pill is the visible state; the expanded panel takes over as the
    /// geometry source once it is on screen.
    var isSource: Bool = true

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

    /// On the real notch, working already shows the equalizer bars right next to the
    /// mascot in a strip barely wider than the camera housing itself — crowded enough
    /// that the turtle reads as a smudge rather than a mascot. Dropping it while working
    /// leaves the bars as the sole activity indicator there. The synthesized pill on an
    /// external display has the room to keep it, so this only applies to the real one.
    private var hidesCreatureWhileWorking: Bool {
        isRealNotch && store.aggregateStatus == .working
    }

    private var leftCluster: some View {
        HStack(spacing: 6) {
            // The turtle is the notch's own mascot (sessions get Claude's critter).
            //
            // Collapsed to zero width rather than removed with `if`: matchedGeometryEffect
            // pairs this instance with the one in the expanded header by id, and pulling a
            // participant out of the tree — instead of just shrinking it — left that pairing
            // with no source to hand off from, which made the expanded header's creature
            // render at zero size too, even though nothing there asked it to.
            PixelCreature(art: .turtle,
                          tint: store.aggregateStatus.creatureTint,
                          height: 18,
                          motion: .forStatus(store.aggregateStatus,
                                             activity: focused?.activity ?? .idle))
                .matchedGeometryEffect(id: MorphID.creature, in: ns, isSource: isSource)
                .frame(width: hidesCreatureWhileWorking ? 0 : nil)
                .opacity(hidesCreatureWhileWorking ? 0 : 1)
                .clipped()
            if store.aggregateStatus == .working {
                WorkingBars(color: Theme.green, activity: focused?.activity ?? .shell)
            }
            Text(store.statusWord)
                .font(Theme.caption)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .fixedSize()
                .matchedGeometryEffect(id: MorphID.status, in: ns, isSource: isSource)
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 6) {
            if store.usage.isLive {
                HStack(spacing: 4) {
                    Text(L(.usageFiveHour)).font(Theme.micro).foregroundStyle(Theme.dim)
                    Text(L10n.percent(Int(store.usage.fiveHourPercent * 100),
                                      Localization.shared.language))
                        .font(Theme.micro).foregroundStyle(Theme.green)
                        .contentTransition(.numericText())
                }
                .animation(Theme.Motion.value, value: store.usage.fiveHourPercent)
                .matchedGeometryEffect(id: MorphID.usage, in: ns, isSource: isSource)
            }
            let n = store.sessions.count
            Text(L(.sessionCountShort, n))
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .contentTransition(.numericText(value: Double(n)))
                .animation(Theme.Motion.value, value: n)
                .matchedGeometryEffect(id: MorphID.count, in: ns, isSource: isSource)
        }
    }

}
