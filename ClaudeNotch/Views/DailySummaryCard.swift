import SwiftUI

/// "Today" at a glance, under the session list: how many turns finished, how long they
/// ran, what they changed, and where. One line folded; the projects unfold beneath it.
struct DailySummaryCard: View {
    @Bindable var store: SessionStore
    var log = DailyLog.shared
    @AppStorage("dailyCardExpanded") private var expanded = false

    var body: some View {
        // Re-read every minute so "today" rolls over at midnight without an event.
        TimelineView(.everyMinute) { context in
            let summary = log.today(now: context.date)
            if !summary.isEmpty || store.usage.todayTokens > 0 {
                card(summary)
            }
        }
    }

    private func card(_ s: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.Motion.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(L(.dailyTitle).uppercased())
                        .font(Theme.micro).foregroundStyle(Theme.dim)
                    if s.turns > 0 {
                        stat(Lcount(.dailyTurnsOne, .dailyTurnsMany, s.turns), Theme.text)
                        stat(duration(s.duration), Theme.textDim)
                    }
                    if s.added > 0 || s.removed > 0 {
                        stat("+\(s.added)", Theme.green)
                        stat("−\(s.removed)", Theme.red)
                    }
                    if s.failures > 0 {
                        stat(Lcount(.dailyFailedOne, .dailyFailedMany, s.failures), Theme.red)
                    }
                    if store.usage.todayTokens > 0 {
                        stat(L(.tokensShort, Lcompact(store.usage.todayTokens)), Theme.textDim)
                    }
                    Spacer(minLength: 0)
                    if !s.projects.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !s.projects.isEmpty {
                FlowChips(items: s.projects)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.5))
        )
    }

    private func stat(_ text: String, _ tint: Color) -> some View {
        Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(tint)
            .lineLimit(1).fixedSize()
    }

    private func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        if minutes >= 60 { return "\(minutes / 60)\(L(.unitHour))\(minutes % 60)\(L(.unitMinute))" }
        return "\(max(minutes, t > 0 ? 1 : 0))\(L(.unitMinute))"
    }
}

/// Project names as small chips, wrapping onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { name in
                Text(name)
                    .font(Theme.micro).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.surfaceHi))
            }
        }
    }
}

/// Minimal flow layout: left to right, wrapping at the proposed width.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
