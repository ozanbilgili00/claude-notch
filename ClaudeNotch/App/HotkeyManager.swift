import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys using Carbon's RegisterEventHotKey, which — unlike an
/// NSEvent monitor — fires while another app is focused and needs no Accessibility
/// permission. That matters: the whole point of the notch is answering Claude without
/// leaving the terminal, so its shortcuts must work when the panel isn't key.
///
/// IDs are caller-assigned; `onHotkey` receives the id that fired.
final class HotkeyManager {
    /// ⌥Space — toggle the notch. Always registered.
    static let toggleID: UInt32 = 1
    /// ⌥1 / ⌥2 / ⌥3 — answer a pending question. Registered only while one is up,
    /// so the keys stay free the rest of the time.
    static func questionID(index: Int) -> UInt32 { UInt32(100 + index) }

    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    /// Called on the main queue with the id of the hotkey that fired.
    var onHotkey: ((UInt32) -> Void)?

    /// Back-compat convenience for the toggle hotkey.
    var onToggle: (() -> Void)?

    func start() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            // Which hotkey fired? The id travels in the event's direct object.
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }

            let id = hotKeyID.id
            DispatchQueue.main.async {
                manager.onHotkey?(id)
                if id == HotkeyManager.toggleID { manager.onToggle?() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Registers the notch toggle (⌥Space) and installs the shared handler.
    func register() {
        start()
        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), id: Self.toggleID)
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        guard hotKeys[id] == nil else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("NOCH"), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeys[id] = ref }
    }

    func unregister(id: UInt32) {
        guard let ref = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    func unregisterAll() {
        for (_, ref) in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func fourCharCode(_ s: String) -> FourCharCode {
        var result: FourCharCode = 0
        for ch in s.utf16.prefix(4) { result = (result << 8) + FourCharCode(ch) }
        return result
    }
}
