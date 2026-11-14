import SwiftUI

/// The detail card that pops out beside a ring: what the ring is, how full it is, and when
/// it resets. Deliberately one screenful of one thing — the ring already said the number,
/// so the card's job is the context around it.
struct EdgeBubbleView: View {
    let kind: UsageRingKind
    let progress: Double
    let tint: Color
    let resetsIn: String?
    /// Only the sessions ring uses this; usage rings leave it nil.
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(kind.title)
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }

            // A bar as well as the ring: the ring is readable at a glance but hard to read
            // precisely, and this is the view you open when you want to know exactly.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke)
                    Capsule().fill(tint)
                        .frame(width: max(3, geometry.size.width * min(max(progress, 0), 1)))
                        .animation(Theme.Motion.value, value: progress)
                }
            }
            .frame(height: 5)

            // Stacked, not side by side: "%54 kullanıldı" and "4sa33dk sonra sıfırlanır"
            // together are wider than the card, and on one row the reset line — the half
            // you opened the card to read — is the one that gets clipped.
            VStack(alignment: .leading, spacing: 3) {
                Text("\(L10n.percent(Int(min(max(progress, 0), 1) * 100), Localization.shared.language)) \(L(.edgeUsed))")
                    .font(Theme.micro).foregroundStyle(Theme.textDim)
                if let resetsIn {
                    Text(String(format: L(.edgeResetsIn), resetsIn))
                        .font(Theme.micro).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle {
                Text(subtitle).font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 13)
        // Room for the tail: the shape's right edge is inset by the tail's width, so the
        // text must stop before it or it runs under the point.
        .padding(.trailing, 13 + EdgeGeometry.tailWidth)
    }
}
