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
                ProgressArc(progress: clamped, tint: tint, lineWidth: 5)
                Text(L10n.percent(Int(clamped * 100), Localization.shared.language))
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: clamped))
                    .animation(Theme.Motion.value, value: Int(clamped * 100))
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
            if usage.weekTokens > 0 {
                tokenTotals
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

    /// Fresh input + output across every session, from `TokenLedger`.
    private var tokenTotals: some View {
        HStack(spacing: 10) {
            Text(L(.usageToday, Lcompact(usage.todayTokens)))
                .contentTransition(.numericText(value: Double(usage.todayTokens)))
            Text(L(.usageThisWeek, Lcompact(usage.weekTokens)))
                .contentTransition(.numericText(value: Double(usage.weekTokens)))
        }
        .font(Theme.micro).foregroundStyle(Theme.textDim)
        .animation(Theme.Motion.value, value: usage.weekTokens)
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
