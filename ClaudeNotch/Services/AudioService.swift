import AppKit
import CoreAudio
import Observation

/// The system mixer: output device, its volume and mute, the input device's level, and
/// the volume of the individual apps that expose one.
///
/// The honest limit, stated once here because it shapes the whole design: **macOS has no
/// public API for per-application volume.** The per-app sliders you see in tools that
/// claim otherwise are backed by a virtual audio driver the user has to install, which
/// intercepts the system's output and re-mixes it. Shipping a kernel-adjacent driver from
/// a notch companion is not a trade worth making, so the app rows here are limited to the
/// apps that publish a volume of their own over AppleScript (Spotify, Music). Everything
/// else is the real system mixer, read and written through CoreAudio directly.
///
/// Cost model matches the rest of the app: CoreAudio pushes changes to us through
/// property listeners, so nothing polls. Turning the volume up from the keyboard moves
/// the slider here without a timer anywhere.
@MainActor
@Observable
final class AudioService {

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    private(set) var outputDevices: [Device] = []
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// 0…1. Held locally while a drag is in flight so the slider doesn't fight the
    /// listener callbacks that our own writes provoke.
    var outputVolume: Double = 0
    var inputVolume: Double = 0
    private(set) var outputMuted = false
    private(set) var inputMuted = false

    /// False when the current device exposes no settable volume at all — most digital
    /// outputs (HDMI, some USB DACs) hand volume control to the receiver. The UI says so
    /// rather than showing a slider that silently does nothing.
    private(set) var outputVolumeAvailable = false
    private(set) var inputVolumeAvailable = false

    /// Every app that is currently putting sound through the system.
    private(set) var apps: [AppVolume] = []

    struct AppVolume: Identifiable, Equatable {
        let id: String          // bundle identifier
        let name: String
        var volume: Double      // 0…1
        let icon: NSImage?
        /// How this app's volume is actually driven — see `Control`.
        let control: Control
        /// Set when a tap was asked for and Core Audio refused (see `AudioService.apply`).
        var failed = false

        /// Two ways to move an app's volume, in order of preference.
        ///
        /// `.scriptable` is a real volume knob inside the app itself, reached over
        /// AppleScript. Nothing is intercepted, and the number matches what the app shows
        /// its own user — so Spotify's row here and the Music tab's slider stay the same
        /// value rather than multiplying into each other.
        ///
        /// `.tap` is for everything else — Safari, Chrome, games, anything at all. macOS
        /// exposes no volume for those, so the level is applied by muting the app at the
        /// source and replaying its audio at a gain. See `ProcessTapController`.
        enum Control: Equatable {
            case scriptable
            case tap(AudioObjectID)
        }
    }

    /// The block has to be kept: `AudioObjectRemovePropertyListenerBlock` matches on the
    /// block's identity, so handing it a fresh closure removes nothing and every device
    /// switch would pile another live listener onto the last one.
    /// The level to come back to when un-muting a device that has no mute switch of its
    /// own — see `setOutputMuted`.
    private var outputVolumeBeforeMute: Double = 0.5
    private var inputVolumeBeforeMute: Double = 0.5
    private var outputMuteSupported = false
    private var inputMuteSupported = false

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var viewers = 0
    private var appRefresh: Task<Void, Never>?

    /// The one engine that carries every tapped app. Deliberately **not** tied to
    /// `viewers`: an app the user turned down stays turned down after the panel closes,
    /// which is the whole point of a mixer.
    private let mixer = ProcessTapMixer()
    /// Where a per-app slider goes back to when its mute button is pressed again.
    private var appVolumeBeforeMute: [String: Double] = [:]

    /// Apps whose tap Core Audio refused, with the status it refused with. Kept separately
    /// from `taps` on purpose: a failed attempt leaves no controller behind (it is torn
    /// down so the app keeps its sound), so without this the UI had no way to know the
    /// slider it is drawing does nothing.
    private var tapFailures: [String: OSStatus] = [:]

    /// True while a per-app slider is being dragged.
    private var isAdjustingApp = false

    /// Last known volume of the apps that answer AppleScript, and the fetch that keeps it
    /// current. Cached because reading it means launching `osascript`, and that must never
    /// happen on the main thread — see `refreshScriptedVolumes`.
    private var scriptedVolumes: [String: Double] = [:]
    private var scriptedFetch: Task<Void, Never>?

    /// Whether the tap machinery may run at all (Settings → Ses karıştırıcı). Off means
    /// the mixer lists only apps with a volume of their own, and Core Audio is never asked
    /// to tap anything.
    var tapsEnabled: Bool {
        didSet {
            guard tapsEnabled != oldValue else { return }
            UserDefaults.standard.set(tapsEnabled, forKey: "appVolumeTaps")
            if !tapsEnabled { releaseAllTaps() }
            refreshApps()
        }
    }

    init() {
        tapsEnabled = UserDefaults.standard.appVolumeTaps
    }

    // MARK: Lifecycle

    /// Only live while a mixer view is on screen. CoreAudio listeners are cheap but the
    /// app-volume rows cost an Apple Event each, so they stay off otherwise.
    func addViewer() {
        viewers += 1
        if viewers == 1 {
            refreshDevices()
            installListeners()
            startAppRefresh()
        }
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        // The panel can collapse mid-drag, and then the slider's "editing ended" never
        // arrives — without this the refresh would stay suspended for good.
        isAdjustingApp = false
        if viewers == 0 {
            removeListeners()
            appRefresh?.cancel()
            appRefresh = nil
        }
    }

    // MARK: Devices

    func refreshDevices() {
        outputDevices = CoreAudioBridge.devices(scope: kAudioObjectPropertyScopeOutput)
            .map { Device(id: $0.0, name: $0.1) }
        outputDeviceID = CoreAudioBridge.defaultDevice(output: true)
        inputDeviceID = CoreAudioBridge.defaultDevice(output: false)
        readLevels()
    }

    func selectOutput(_ device: Device) {
        guard device.id != outputDeviceID else { return }
        CoreAudioBridge.setDefaultDevice(device.id, output: true)
        // The listener will fire too, but writing it now keeps the menu from flickering
        // back to the old name for a frame.
        outputDeviceID = device.id
        installListeners()
        readLevels()
    }

    var outputDeviceName: String {
        outputDevices.first { $0.id == outputDeviceID }?.name
            ?? CoreAudioBridge.name(of: outputDeviceID)
            ?? ""
    }

    private func readLevels() {
        outputVolumeAvailable = CoreAudioBridge.hasVolume(outputDeviceID, output: true)
        inputVolumeAvailable = CoreAudioBridge.hasVolume(inputDeviceID, output: false)
        outputVolume = CoreAudioBridge.volume(outputDeviceID, output: true) ?? 0
        inputVolume = CoreAudioBridge.volume(inputDeviceID, output: false) ?? 0
        outputMuteSupported = CoreAudioBridge.hasMute(outputDeviceID, output: true)
        inputMuteSupported = CoreAudioBridge.hasMute(inputDeviceID, output: false)
        // A device without a mute switch is "muted" exactly when its level is zero —
        // which is also what the mute button does to it, below.
        outputMuted = outputMuteSupported
            ? (CoreAudioBridge.muted(outputDeviceID, output: true) ?? false)
            : outputVolume <= 0.0001
        inputMuted = inputMuteSupported
            ? (CoreAudioBridge.muted(inputDeviceID, output: false) ?? false)
            : inputVolume <= 0.0001
    }

    // MARK: Writing

    /// Live during a drag: CoreAudio takes scalar writes at gesture rate happily — unlike
    /// the Spotify path, there is no subprocess involved.
    func setOutputVolume(_ value: Double) {
        setOutputVolumeSilently(value)
        // Nudging the slider off zero on a muted device is a request to hear something.
        if outputMuted, outputVolume > 0, outputMuteSupported { setOutputMuted(false) }
        else if outputVolume > 0 { outputMuted = false }
    }

    func setInputVolume(_ value: Double) {
        setInputVolumeSilently(value)
        if inputMuted, inputVolume > 0, inputMuteSupported { setInputMuted(false) }
        else if inputVolume > 0 { inputMuted = false }
    }

    /// AirPods and most USB outputs publish a volume but no settable mute, so the button
    /// falls back to driving the level to zero. That fallback has to remember where the
    /// level was: without it, un-muting writes `mute = false` to a property nothing reads
    /// and leaves the device sitting at silent zero.
    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        if outputMuteSupported {
            CoreAudioBridge.setMuted(muted, on: outputDeviceID, output: true)
        } else if muted {
            outputVolumeBeforeMute = max(0.05, outputVolume)
            setOutputVolumeSilently(0)
        } else {
            setOutputVolumeSilently(outputVolumeBeforeMute)
        }
    }

    func setInputMuted(_ muted: Bool) {
        inputMuted = muted
        if inputMuteSupported {
            CoreAudioBridge.setMuted(muted, on: inputDeviceID, output: false)
        } else if muted {
            inputVolumeBeforeMute = max(0.05, inputVolume)
            setInputVolumeSilently(0)
        } else {
            setInputVolumeSilently(inputVolumeBeforeMute)
        }
    }

    /// Writes the level without the un-mute-on-nudge rule in `setOutputVolume`, which
    /// would otherwise undo the mute it was called from.
    private func setOutputVolumeSilently(_ value: Double) {
        outputVolume = min(1, max(0, value))
        CoreAudioBridge.setVolume(outputVolume, on: outputDeviceID, output: true)
    }

    private func setInputVolumeSilently(_ value: Double) {
        inputVolume = min(1, max(0, value))
        CoreAudioBridge.setVolume(inputVolume, on: inputDeviceID, output: false)
    }

    func toggleOutputMute() { setOutputMuted(!outputMuted) }
    func toggleInputMute() { setInputMuted(!inputMuted) }

    // MARK: Listeners

    private func installListeners() {
        removeListeners()
        let system = AudioObjectID(kAudioObjectSystemObject)
        watch(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        watch(system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        watch(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        for element in CoreAudioBridge.volumeElements {
            watch(outputDeviceID, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            watch(inputDeviceID, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
        }
        watch(outputDeviceID, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        watch(inputDeviceID, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope,
                       _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        guard object != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.propertyChanged(selector) }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr
        else { return }
        listeners.append((object, address, block))
    }

    private func propertyChanged(_ selector: AudioObjectPropertySelector) {
        switch selector {
        case kAudioHardwarePropertyDefaultOutputDevice,
             kAudioHardwarePropertyDefaultInputDevice,
             kAudioHardwarePropertyDevices:
            refreshDevices()
            // Deferred by one runloop turn on purpose. We are *inside* a CoreAudio
            // listener callback here, and re-installing listeners means removing the very
            // block that is currently running while CoreAudio still holds the list —
            // likewise for tearing an aggregate device down from inside its own device's
            // notification. Both are hazards; neither is worth the microsecond saved.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installListeners()
                self.rebuildTaps()
            }
        default:
            readLevels()
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    // MARK: Per-app volume

    /// Apps that publish their own `sound volume` over AppleScript. Reaching for the tap
    /// machinery when the app has a real knob would be worse in every way: an extra audio
    /// path, and a second number competing with the one the app itself shows.
    private static let scriptable: Set<String> = ["com.spotify.client", "com.apple.Music"]

    private func startAppRefresh() {
        appRefresh?.cancel()
        appRefresh = Task { @MainActor in
            while !Task.isCancelled {
                refreshApps()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The list is Core Audio's own: every process object currently running output. That
    /// is what makes Safari, Chrome, a game or a video call show up without knowing
    /// anything about them — if it is making sound, it is in here.
    func refreshApps() {
        // Never while a slider is under the finger: replacing the array mid-drag makes the
        // thumb jump under the pointer and re-enters the tap code for no reason.
        guard !isAdjustingApp else { return }
        let running = NSWorkspace.shared.runningApplications
        let mine = ProcessInfo.processInfo.processIdentifier
        var found: [AppVolume] = []

        for process in CoreAudioBridge.audioProcesses() {
            // Our own playback is the tapped audio we are replaying; listing it would
            // offer the user a slider that turns down everything at once.
            guard process.pid != mine else { continue }
            guard let app = running.first(where: { $0.processIdentifier == process.pid }),
                  let bundleID = app.bundleIdentifier else { continue }
            // An app we are already holding stays listed even while it reports no output:
            // muting it at the source is what stops that report, so trusting it would make
            // the mixer tear down its own tap three seconds after creating it — which is
            // exactly what it did, leaving the slider snapping back to 100 and the audio
            // untouched.
            guard process.isPlaying || mixer.volume(for: bundleID) != nil else { continue }
            // One row per app, not per helper process: Chrome and Safari both play through
            // a helper, and Safari's audio process is a different pid than the browser.
            guard !found.contains(where: { $0.id == bundleID }) else { continue }

            let scriptable = Self.scriptable.contains(bundleID)
            // With taps switched off, an app we cannot script is an app we cannot control:
            // showing it with a dead slider would be worse than not showing it.
            guard scriptable || tapsEnabled else { continue }
            let control: AppVolume.Control = scriptable ? .scriptable : .tap(process.objectID)
            // Everything here is a cached or in-memory read. Nothing in this loop may block:
            // it runs on the main thread every couple of seconds while the tab is open.
            let volume = scriptable
                ? (scriptedVolumes[bundleID] ?? 1)
                : mixer.volume(for: bundleID).map(Double.init) ?? 1
            found.append(AppVolume(id: bundleID,
                                   name: app.localizedName ?? bundleID,
                                   volume: volume,
                                   icon: app.icon,
                                   control: control,
                                   failed: tapFailures[bundleID] != nil))
        }

        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // A tap is released when its app is gone from the list entirely — it quit, or it
        // stopped playing while we were not holding it. Destroying the tap is what hands
        // the audio back, so this must stay reachable.
        for bundleID in mixer.tappedBundleIDs where !found.contains(where: { $0.id == bundleID }) {
            mixer.remove(bundleID)
            tapFailures[bundleID] = nil
        }

        if found != apps { apps = found }
        refreshScriptedVolumes(for: found)
    }

    /// The one place AppleScript is allowed to run, and it runs **off** the main thread.
    ///
    /// This used to be a synchronous `AppleScriptRunner.run` inside `refreshApps`, which
    /// meant a subprocess launch and an Apple Event round-trip on the main thread every
    /// few seconds for as long as the tab was open. A slow answer from Spotify froze the
    /// whole panel — sessions, hooks and all — which is exactly what it looked like.
    private func refreshScriptedVolumes(for apps: [AppVolume]) {
        guard scriptedFetch == nil else { return }
        let ids = apps.filter { $0.control == .scriptable }.map(\.id)
        guard !ids.isEmpty else { return }
        scriptedFetch = Task.detached(priority: .utility) {
            var values: [String: Double] = [:]
            for id in ids {
                let read = AppleScriptRunner.run(
                    "tell application id \"\(id)\" to get sound volume", timeout: 3)
                if let value = read.flatMap(Double.init) { values[id] = value / 100 }
            }
            await MainActor.run { [values] in
                self.scriptedFetch = nil
                guard !values.isEmpty else { return }
                self.scriptedVolumes.merge(values) { _, new in new }
                for index in self.apps.indices {
                    guard self.apps[index].control == .scriptable,
                          let value = values[self.apps[index].id] else { continue }
                    self.apps[index].volume = value
                }
            }
        }
    }

    /// Live during a drag. A tap's gain is a plain multiply on the audio thread, so it can
    /// follow the pointer; the scriptable apps wait for `commitAppVolume`.
    func beginAdjustingApp() { isAdjustingApp = true }
    func endAdjustingApp() { isAdjustingApp = false }

    func setAppVolume(_ value: Double, for id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        let level = min(1, max(0, value))
        apps[index].volume = level
        guard case .tap(let objectID) = apps[index].control else { return }
        apply(level, to: id, objectID: objectID)
        apps[index].failed = tapFailures[id] != nil
    }

    /// Called when the drag ends — one Apple Event for the whole gesture, the same
    /// contract `SpotifyService.commitVolume` uses. Taps have already followed the drag.
    func commitAppVolume(for id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        switch app.control {
        case .tap:
            break   // the tap already follows the drag; nothing to commit
        case .scriptable:
            scriptedVolumes[id] = app.volume
            let level = Int((app.volume * 100).rounded())
            Task.detached {
                AppleScriptRunner.run("tell application id \"\(id)\" to set sound volume to \(level)",
                                      timeout: 5)
            }
        }
    }

    func toggleAppMute(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        if app.volume > 0 {
            appVolumeBeforeMute[id] = app.volume
            setAppVolume(0, for: id)
        } else {
            setAppVolume(appVolumeBeforeMute[id] ?? 0.5, for: id)
        }
        commitAppVolume(for: id)
    }

    /// Full volume means *no interception at all*: the tap is destroyed and the app goes
    /// back to talking to the output device directly. Anything less builds one.
    /// Full volume is **not** a reason to tear the tap down. Dragging a slider to the end
    /// and back would otherwise create and destroy a tap, an aggregate device and a
    /// real-time callback on every pass — the kind of churn that upsets `coreaudiod`, and
    /// when that stumbles every app on the Mac stumbles with it. A gain of 1.0 is already
    /// transparent; the tap is released when the app stops playing or the feature is
    /// switched off.
    private func apply(_ level: Double, to bundleID: String, objectID: AudioObjectID) {
        let existing = mixer.volume(for: bundleID) != nil
        if mixer.setVolume(Float(level), for: bundleID, process: objectID,
                           outputDevice: outputDeviceID) {
            if !existing { debugLog("tap started for \(bundleID) at \(Int(level * 100))%") }
            tapFailures[bundleID] = nil
        } else {
            tapFailures[bundleID] = mixer.lastError
            debugLog("tap failed for \(bundleID): \(Self.fourCC(mixer.lastError))")
        }
    }

    /// Diagnostics for the tap path, off unless `NOTCH_DEBUG=1`. The mixer is the one
    /// feature whose failures are silent by nature — a tap that never starts looks exactly
    /// like a slider that does nothing.
    private func debugLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" else { return }
        fputs("[mixer] \(line)\n", stderr)
    }

    /// CoreAudio reports failures as four-character codes; printed raw they are unreadable
    /// negative integers.
    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(status)" }
        return String(bytes: bytes, encoding: .ascii) ?? "\(status)"
    }

    /// Speakers changed: an aggregate device is pinned to the output device it was built
    /// around, so every live tap has to be rebuilt or its audio goes to the old one.
    private func rebuildTaps() {
        mixer.retarget(outputDevice: outputDeviceID)
    }

    /// Hands every tapped app its own audio path back. Called when the app quits — macOS
    /// would do it anyway when the process dies, but not until then.
    func releaseAllTaps() {
        mixer.removeAll()
    }
}
