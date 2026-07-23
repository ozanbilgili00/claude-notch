import SwiftUI

/// The full panel: a usage header, then a stack of session cards. A card that is
/// blocking (permission or question) expands inline to show the diff / choices.
struct ExpandedView: View {
    @Bindable var store: SessionStore
    @Bindable var model: NotchViewModel
    var ns: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            UsageHeaderView(store: store)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.sessions) { session in
                        SessionRowView(store: store, session: session)
                    }
                    if store.sessions.isEmpty {
                        EmptyStateView(usage: store.usage)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Theme.text)
    }
}

/// Top strip: 5h / 7d usage percentages + reset countdowns and window controls.
struct UsageHeaderView: View {
    @Bindable var store: SessionStore
    @AppStorage("muteSounds") private var muteSounds = false
    @State private var hoverSound = false
    @State private var hoverGear = false

    var body: some View {
        HStack(spacing: 10) {
            usageStat(label: "5h", pct: store.usage.fiveHourPercent, resets: store.usage.fiveHourResetsIn)
            usageStat(label: "7d", pct: store.usage.weeklyPercent, resets: store.usage.weeklyResetsIn)

            Spacer()

            if !store.usage.isLive {
                Badge(text: "local usage", tint: Theme.dim)
            }

            // Mute / unmute notification sounds.
            iconButton(muteSounds ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       hover: $hoverSound, tint: muteSounds ? Theme.amber : Theme.dim) {
                muteSounds.toggle()
            }

            // Open Settings.
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(hoverGear ? Theme.text : Theme.dim)
            }
            .buttonStyle(.plain)
            .onHover { hoverGear = $0 }
        }
    }

    private func iconButton(_ symbol: String, hover: Binding<Bool>, tint: Color,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(hover.wrappedValue ? Theme.text : tint)
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }

    private func usageStat(label: String, pct: Double, resets: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textDim)
            Text("\(Int(pct * 100))%")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(pct > 0.85 ? Theme.red : Theme.green)
            Text(resets).font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }
}

struct EmptyStateView: View {
    let usage: UsageSnapshot
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                PixelIcon(pattern: PixelIcon.invader, color: Theme.dim, pixel: 3)
                Text("No active Claude Code sessions")
                    .font(Theme.caption).foregroundStyle(Theme.dim)
                Text("Start `claude` in a terminal to see it here")
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
            UsageDashboardView(usage: usage)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
