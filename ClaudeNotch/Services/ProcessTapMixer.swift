import CoreAudio
import AudioToolbox
import Foundation

/// Per-application volume, without an audio driver.
///
/// macOS has no "set this app's volume" call. What it does have, since macOS 14.2, is a
/// *process tap*: Core Audio can hand you one process's output and mute that process while
/// you hold it. This class turns that into a volume control — take the app's audio, scale
/// it, play it back — and it is deliberately built as **one engine for every app**, not one
/// per app.
///
/// That is the whole design decision, and it was learned the hard way. An aggregate device
/// per tapped app means several private aggregate devices driving the same speakers at the
/// same time, each with its own real-time callback and its own clock. Creating and
/// destroying them repeatedly is worse still: it hammers `coreaudiod`, and when that
/// stumbles every app on the Mac that touches audio stumbles with it. So:
///
/// - **One aggregate device, one IOProc, N taps.** Adding or removing an app rebuilds that
///   single device once; the taps themselves survive the rebuild.
/// - **A tap is created once per app and kept** until the app stops playing, the user
///   switches the feature off, or Claude Notch quits. Returning a slider to 100% sets its
///   gain to 1.0 rather than tearing the tap down, so dragging a slider back and forth
///   cannot churn the audio system.
/// - **The IOProc allocates nothing, locks nothing, and logs nothing.** It runs on a
///   real-time thread with a hard deadline.
/// - **Every exit path destroys the taps**, because that is what un-mutes the apps. If the
///   process is killed outright, macOS does it for us.
@MainActor
final class ProcessTapMixer {

    /// Deliberately small. Each entry is a live tap on someone's audio; a mixer with more
    /// than a handful of channels is a sign something is looping, not a Mac with nine apps
    /// playing at once.
    static let capacity = 8

    private struct Entry {
        let bundleID: String
        let processObjectID: AudioObjectID
        var tapID: AudioObjectID
    }

    private var entries: [Entry] = []
    private var aggregateID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDevice = kAudioObjectUnknown
    private var running = false

    /// Gains indexed the same way the aggregate's input buffers are: entry *i* is tap *i*.
    private let gains = GainTable(capacity: ProcessTapMixer.capacity)

    private(set) var lastError: OSStatus = noErr

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    deinit {
        ProcessTapMixer.teardown(ioProcID: ioProcID, aggregate: aggregateID,
                                 taps: entries.map(\.tapID))
    }

    var tappedBundleIDs: [String] { entries.map(\.bundleID) }

    func volume(for bundleID: String) -> Float? {
        guard let index = entries.firstIndex(where: { $0.bundleID == bundleID }) else { return nil }
        return gains[index]
    }

    // MARK: Channels

    /// Sets an app's level, creating its tap the first time. Returns false only if the tap
    /// could not be created — in which case nothing was left behind and the app keeps its
    /// own audio path.
    @discardableResult
    func setVolume(_ level: Float, for bundleID: String, process: AudioObjectID,
                   outputDevice device: AudioDeviceID) -> Bool {
        guard Self.isSupported else {
            lastError = kAudioHardwareIllegalOperationError
            return false
        }
        if let index = entries.firstIndex(where: { $0.bundleID == bundleID }) {
            gains[index] = level
            return true
        }
        guard entries.count < Self.capacity else {
            lastError = kAudioHardwareIllegalOperationError
            return false
        }
        guard let tapID = Self.makeTap(for: process) else {
            lastError = kAudioHardwareUnspecifiedError
            return false
        }
        entries.append(Entry(bundleID: bundleID, processObjectID: process, tapID: tapID))
        gains[entries.count - 1] = level
        outputDevice = device
        guard rebuild() else {
            // Rebuilding failed: drop the tap we just made rather than leave the app muted
            // with nothing playing it back.
            remove(bundleID)
            return false
        }
        return true
    }

    /// Releases one app — this is what gives it its own audio back.
    func remove(_ bundleID: String) {
        guard let index = entries.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let entry = entries.remove(at: index)
        // Gains shift with the entries, since both are indexed by position.
        for position in index..<entries.count { gains[position] = gains[position + 1] }
        gains[entries.count] = 1
        stopEngine()
        Self.destroyTap(entry.tapID)
        _ = rebuild()
    }

    func removeAll() {
        stopEngine()
        for entry in entries { Self.destroyTap(entry.tapID) }
        entries.removeAll()
        for index in 0..<Self.capacity { gains[index] = 1 }
    }

    /// The speakers changed. An aggregate device is pinned to the device it was built
    /// around, so the engine is rebuilt on the new one; the taps are untouched.
    func retarget(outputDevice device: AudioDeviceID) {
        guard device != outputDevice, !entries.isEmpty else {
            outputDevice = device
            return
        }
        outputDevice = device
        _ = rebuild()
    }

    // MARK: Engine

    /// Tears the single aggregate device down and builds it again around the current tap
    /// list. Called once per membership change — never per slider move.
    @discardableResult
    private func rebuild() -> Bool {
        stopEngine()
        guard !entries.isEmpty else { return true }
        guard let deviceUID = Self.deviceUID(outputDevice) else {
            lastError = kAudioHardwareBadDeviceError
            return false
        }

        let taps: [[String: Any]] = entries.compactMap { entry in
            guard let uid = Self.tapUID(entry.tapID) else { return nil }
            return [kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]
        }
        guard taps.count == entries.count else {
            lastError = kAudioHardwareUnspecifiedError
            return false
        }

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Claude Notch Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            // Private: no entry in Audio MIDI Setup, and no device for other apps to pick
            // by accident.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: taps
        ]
        var status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard status == noErr else { return fail(status) }

        // The mix below writes 32-bit floats. If this device speaks anything else, writing
        // floats into its buffers would not be quiet or wrong-sounding — it would be noise
        // at full scale. Refuse instead, and let the app keep its own audio path.
        guard Self.isFloat32(aggregateID) else { return fail(kAudioDeviceUnsupportedFormatError) }

        let table = gains
        let channels = entries.count
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let sinks = UnsafeMutableAudioBufferListPointer(output)
            // The device hands us whatever happened to be in its buffers; every app's
            // audio is summed into them, so they all have to start from silence — not just
            // the one we mix into, or the others play back stale memory.
            for sink in sinks {
                guard let data = sink.mData else { continue }
                memset(data, 0, Int(sink.mDataByteSize))
            }
            guard let sink = sinks.first, let destination = sink.mData else { return }
            let outBytes = Int(sink.mDataByteSize)
            let write = destination.assumingMemoryBound(to: Float.self)
            let outCount = outBytes / MemoryLayout<Float>.size

            for index in 0..<min(sources.count, channels) {
                let source = sources[index]
                guard let from = source.mData else { continue }
                let level = table[index]
                if level == 0 { continue }
                let read = from.assumingMemoryBound(to: Float.self)
                let count = min(outCount, Int(source.mDataByteSize) / MemoryLayout<Float>.size)
                for frame in 0..<count { write[frame] += read[frame] * level }
            }
        }
        guard status == noErr, ioProcID != nil else { return fail(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { return fail(status) }

        running = true
        lastError = noErr
        return true
    }

    /// Stops and destroys the aggregate device, leaving the taps alone.
    private func stopEngine() {
        if running, aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = kAudioObjectUnknown
        running = false
    }

    private func fail(_ status: OSStatus) -> Bool {
        lastError = status
        stopEngine()
        return false
    }

    private nonisolated static func teardown(ioProcID: AudioDeviceIOProcID?,
                                             aggregate: AudioObjectID,
                                             taps: [AudioObjectID]) {
        if let ioProcID, aggregate != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregate, ioProcID)
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        taps.forEach(destroyTap)
    }

    // MARK: CoreAudio

    private static func makeTap(for process: AudioObjectID) -> AudioObjectID? {
        guard #available(macOS 14.2, *) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = "Claude Notch"
        description.uuid = UUID()
        description.isPrivate = true
        // The point of the exercise: the app goes silent on its own path and reaches the
        // speakers only through the mix above.
        description.muteBehavior = .mutedWhenTapped
        var tapID = kAudioObjectUnknown
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
              tapID != kAudioObjectUnknown else { return nil }
        return tapID
    }

    nonisolated static func destroyTap(_ id: AudioObjectID) {
        guard id != kAudioObjectUnknown, #available(macOS 14.2, *) else { return }
        AudioHardwareDestroyProcessTap(id)
    }

    /// Whether the device's output stream is packed 32-bit float — the only layout the
    /// mix loop knows how to write.
    static func isFloat32(_ id: AudioDeviceID) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format) == noErr
        else { return false }
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        guard id != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String : nil
    }

    static func tapUID(_ id: AudioObjectID) -> String? {
        guard id != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String : nil
    }
}

/// Gains the audio thread reads while the main thread writes them.
///
/// Plain aligned `Float` slots and deliberately **no lock**. Anything that can block — a
/// mutex, an allocation, a Swift runtime call that might allocate — is forbidden inside an
/// IOProc, which runs on a real-time thread with a hard deadline. The worst case without a
/// lock is that one buffer is rendered with the previous gain, which is inaudible; a
/// stalled audio thread is not.
final class GainTable: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 1, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    subscript(index: Int) -> Float {
        get { index >= 0 && index < capacity ? storage[index] : 1 }
        set { if index >= 0 && index < capacity { storage[index] = min(1, max(0, newValue)) } }
    }
}
