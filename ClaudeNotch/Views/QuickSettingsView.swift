import SwiftUI
import AppKit

/// The gear button's panel, drawn inside the notch rather than as a separate window —
/// a real popover would spawn its own window and steal focus from the non-activating
/// notch panel. Holds the handful of switches worth reaching without leaving the notch;
/// everything else lives behind "All Settings…".
struct QuickSettingsView: View {
    var onClose: () -> Void

    @AppStorage("muteSounds") private var muteSounds = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("autoCollapse") private var autoCollapse = true

    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hookError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow(L(.sounds), isOn: Binding(get: { !muteSounds },
                                              set: { muteSounds = !$0 }))
            toggleRow(L(.notifications), isOn: $notifications)
            toggleRow(L(.autoCollapse), isOn: $autoCollapse)

            Divider().overlay(Theme.stroke).padding(.vertical, 4)

            hookRow
            if let hookError {
                Text(hookError)
                    .font(Theme.micro).foregroundStyle(Theme.red)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }

            Divider().overlay(Theme.stroke).padding(.vertical, 4)

            actionRow(L(.allSettings)) {
                onClose()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            actionRow(L(.quitApp)) { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 230)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.surfaceHi)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        )
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.text)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.green)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var hookRow: some View {
        HStack(spacing: 6) {
            Image(systemName: hooksInstalled ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10))
                .foregroundStyle(hooksInstalled ? Theme.green : Theme.dim)
            Text(L(.hooks)).font(Theme.caption).foregroundStyle(Theme.text)
            Spacer()
            Button(hooksInstalled ? L(.remove) : L(.install), action: toggleHooks)
                .buttonStyle(.plain)
                .font(Theme.micro.weight(.medium))
                .foregroundStyle(Theme.blue)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func actionRow(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption).foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same install/uninstall path the Settings window uses.
    private func toggleHooks() {
        do {
            if hooksInstalled { try HookInstaller.uninstall() }
            else { try HookInstaller.install() }
            hooksInstalled = HookInstaller.isInstalled()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }
}
