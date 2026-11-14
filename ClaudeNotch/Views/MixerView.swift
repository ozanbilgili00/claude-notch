import SwiftUI
import AppKit

/// The Mixer tab: system output (device, level, mute), microphone input, and a row per
/// running app that publishes a volume of its own.
///
/// Two columns rather than one long list — the panel is much wider than it is tall, and
/// stacking output over input over the apps would have pushed the app rows off the bottom.
struct MixerView: View {
    @Bindable var audio: AudioService

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                outputSection
                inputSection
            }
            .frame(width: 260)

            appsSection
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { audio.addViewer() }
        .onDisappear { audio.removeViewer() }
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L(.mixerOutput))
            devicePicker
            if audio.outputVolumeAvailable {
                levelRow(symbol: symbol(for: audio.outputVolume, muted: audio.outputMuted),
                         value: audio.outputMuted ? 0 : audio.outputVolume,
                         tint: Theme.green,
                         muted: audio.outputMuted,
                         onMute: { audio.toggleOutputMute() },
                         onChange: { audio.setOutputVolume($0) })
            } else {
                Text(L(.mixerNoVolumeControl))
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    /// A plain menu rather than a segmented control: the list is whatever is plugged in,
    /// which on a laptop with AirPods and an external display is routinely five entries.
    private var devicePicker: some View {
        Menu {
            ForEach(audio.outputDevices) { device in
                Button {
                    audio.selectOutput(device)
                } label: {
                    if device.id == audio.outputDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                Text(audio.outputDeviceName.isEmpty ? L(.mixerNoDevice) : audio.outputDeviceName)
                    .font(Theme.caption).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        // The system's own indicator rather than a hand-drawn chevron: `.borderlessButton`
        // re-lays out the label and centres it, which left a trailing glyph either
        // stranded mid-row or clipped away entirely.
        .menuIndicator(.visible)
        .buttonStyle(.plain)
        // A menu sizes to its label, so without this the row shrink-wraps the device
        // name and sits narrower than the sliders below it — and a shorter name would
        // change the row's width every time the output changed.
        .frame(maxWidth: .infinity)
        // The row's own background, not the label's: `.borderlessButton` re-hosts the
        // label and drops decoration applied inside it, which left this row floating
        // while the sliders under it sat on their panels.
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L(.mixerInput))
            if audio.inputVolumeAvailable {
                levelRow(symbol: audio.inputMuted ? "mic.slash.fill" : "mic.fill",
                         value: audio.inputMuted ? 0 : audio.inputVolume,
                         tint: Theme.blue,
                         muted: audio.inputMuted,
                         onMute: { audio.toggleInputMute() },
                         onChange: { audio.setInputVolume($0) })
            } else {
                Text(L(.mixerNoVolumeControl))
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L(.mixerApps))
            if audio.apps.isEmpty {
                Text(L(.mixerNoApps))
                    .font(Theme.caption).foregroundStyle(Theme.dim)
            } else {
                ForEach(audio.apps) { app in
                    appRow(app)
                }
            }
            // Worth one permanent line, because it describes something the user can feel:
            // an app below full volume has its audio routed through Claude Notch.
            Text(audio.tapsEnabled ? L(.mixerAppsNote) : L(.mixerTapsOffNote))
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            // Only shown when Core Audio actually refused a tap — the normal case needs no
            // explanation, and a permanent disclaimer under a working mixer reads as an
            // apology for something that isn't wrong.
            if audio.apps.contains(where: \.failed) {
                Text(L(.mixerAppFailed))
                    .font(Theme.micro).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func appRow(_ app: AudioService.AppVolume) -> some View {
        HStack(spacing: 8) {
            Button { audio.toggleAppMute(app.id) } label: {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        // The app's own icon is the mute button: dimming it is how a mixer
                        // channel shows it is silenced, and it costs no extra width in a
                        // row that already carries a name, a slider and a number.
                        .opacity(app.volume <= 0.001 ? 0.35 : 1)
                        .overlay(alignment: .bottomTrailing) {
                            if app.volume <= 0.001 {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Theme.red)
                                    .padding(1)
                                    .background(Circle().fill(Theme.ink))
                                    .offset(x: 3, y: 3)
                            }
                        }
                }
            }
            .buttonStyle(.plain)
            .help(L(.mixerMute))

            Text(app.name)
                .font(Theme.caption).foregroundStyle(app.failed ? Theme.dim : Theme.text)
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { app.volume },
                                  set: { audio.setAppVolume($0, for: app.id) }),
                   in: 0...1) { editing in
                if editing { audio.beginAdjustingApp() }
                else {
                    audio.endAdjustingApp()
                    audio.commitAppVolume(for: app.id)
                }
            }
            .controlSize(.mini)
            .tint(Theme.violet)
            Text("\(Int(app.volume * 100))")
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.micro).foregroundStyle(Theme.dim)
            .textCase(.uppercase)
    }

    private func levelRow(symbol: String, value: Double, tint: Color, muted: Bool,
                          onMute: @escaping () -> Void,
                          onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: onMute) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(muted ? Theme.red : Theme.dim)
                    // Fixed width so the row doesn't shift as the glyph changes between
                    // the mute / low / high variants mid-drag.
                    .frame(width: 16, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(L(.mixerMute))

            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
                .controlSize(.mini)
                .tint(muted ? Theme.dim : tint)

            Text("\(Int(value * 100))")
                .font(Theme.micro).foregroundStyle(Theme.dim)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func symbol(for value: Double, muted: Bool) -> String {
        if muted || value <= 0.001 { return "speaker.slash.fill" }
        switch value {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
