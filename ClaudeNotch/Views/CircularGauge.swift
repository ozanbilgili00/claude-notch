import SwiftUI

/// A circular progress ring with a percentage in the center — the "beautiful circular
/// progress indicator" for the usage dashboard.
struct CircularGauge: View {
    var progress: Double        // 0...1
    var label: String           // "5h"
    var caption: String         // reset countdown, e.g. "4h10m"
    var tint: Color
    var size: CGFloat = 54

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Theme.stroke, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.Motion.quick, value: clamped)
                Text(L10n.percent(Int(clamped * 100), Localization.shared.language))
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)

            Text(label).font(Theme.micro).foregroundStyle(Theme.textDim)
            Text(caption).font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }
}

/// Usage rings shown where there's room (the empty state), giving an at-a-glance
/// read of the 5-hour and weekly windows.
struct UsageDashboardView: View {
    let usage: UsageSnapshot

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                CircularGauge(progress: usage.fiveHourPercent, label: L(.usageFiveHourLong),
                              caption: usage.fiveHourResetsIn, tint: tint(usage.fiveHourPercent))
                CircularGauge(progress: usage.weeklyPercent, label: L(.usageWeeklyLong),
                              caption: usage.weeklyResetsIn, tint: tint(usage.weeklyPercent))
                // Plans without a separate Opus allowance simply don't get this ring.
                if let opus = usage.opusPercent {
                    CircularGauge(progress: opus, label: L(.usageOpusLong),
                                  caption: usage.opusResetsIn, tint: tint(opus))
                }
            }
            if let used = usage.extraCreditsUsed {
                extraCredits(used: used, limit: usage.extraCreditsLimit)
            }
            if !usage.isLive {
                Text(L(.usageSignIn))
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    /// Pay-as-you-go credits, shown only when the account has them enabled.
    private func extraCredits(used: Double, limit: Double?) -> some View {
        HStack(spacing: 4) {
            Text(L(.usageExtraCredits)).font(Theme.micro).foregroundStyle(Theme.dim)
            Text(limit.map { "$\(fmt(used)) / $\(fmt($0))" } ?? "$\(fmt(used))")
                .font(Theme.micro.weight(.semibold)).foregroundStyle(Theme.textDim)
        }
    }

    /// The dollar sign stays — Anthropic bills in USD regardless of display language —
    /// but the decimal separator follows it.
    private func fmt(_ v: Double) -> String {
        L10n.decimal(v, Localization.shared.language)
    }

    private func tint(_ pct: Double) -> Color {
        pct > 0.85 ? Theme.red : (pct > 0.6 ? Theme.amber : Theme.green)
    }
}
