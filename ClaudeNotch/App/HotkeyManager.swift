import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey (⌥Space by default) to toggle the notch, using Carbon's
/// RegisterEventHotKey so it needs no Accessibility permission.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onToggle: (() -> Void)?

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onToggle?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let id = EventHotKeyID(signature: fourCharCode("NOCH"), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func fourCharCode(_ s: String) -> FourCharCode {
        var result: FourCharCode = 0
        for ch in s.utf16.prefix(4) { result = (result << 8) + FourCharCode(ch) }
        return result
    }
}
