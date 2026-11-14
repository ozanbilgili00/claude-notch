import CoreAudio

/// Thin, synchronous wrapper over the CoreAudio property calls. Free of state on purpose:
/// every function here is a direct read or write, so `AudioService` owns all caching.
enum CoreAudioBridge {

    /// Element 0 is the device's own master control. Devices that don't implement it
    /// (most USB interfaces) expose per-channel controls instead, and stereo is channels
    /// 1 and 2 — so those are tried in order.
    static let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    static func defaultDevice(output: Bool) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice
                              : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &id)
        return status == noErr ? id : kAudioObjectUnknown
    }

    static func setDefaultDevice(_ id: AudioDeviceID, output: Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice
                              : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    /// Every device that carries at least one channel in `scope`. A Mac lists aggregate
    /// and virtual devices alongside real ones; the channel count is what separates an
    /// output device from an input-only one.
    static func devices(scope: AudioObjectPropertyScope) -> [(AudioDeviceID, String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard channelCount(id, scope: scope) > 0, let name = name(of: id) else { return nil }
            return (id, name)
        }
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func name(of id: AudioDeviceID) -> String? {
        guard id != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement,
                                      output: Bool) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
            mElement: element)
    }

    /// The first element that both exists and can be written. Read-only volume is common
    /// on HDMI and optical outputs, and is reported as "no control" rather than as zero.
    static func settableElement(_ id: AudioDeviceID, output: Bool) -> AudioObjectPropertyElement? {
        guard id != kAudioObjectUnknown else { return nil }
        for element in volumeElements {
            var address = volumeAddress(element, output: output)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue
            else { continue }
            return element
        }
        return nil
    }

    static func hasVolume(_ id: AudioDeviceID, output: Bool) -> Bool {
        settableElement(id, output: output) != nil
    }

    static func volume(_ id: AudioDeviceID, output: Bool) -> Double? {
        guard let element = settableElement(id, output: output) else { return nil }
        var address = volumeAddress(element, output: output)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return Double(value)
    }

    /// Written to every channel the device exposes, not just the one we read from —
    /// setting channel 1 alone on a stereo device pans everything left.
    static func setVolume(_ value: Double, on id: AudioDeviceID, output: Bool) {
        guard id != kAudioObjectUnknown else { return }
        var scalar = Float32(min(1, max(0, value)))
        for element in volumeElements {
            var address = volumeAddress(element, output: output)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue
            else { continue }
            AudioObjectSetPropertyData(id, &address, 0, nil,
                                       UInt32(MemoryLayout<Float32>.size), &scalar)
        }
    }

    private static func muteAddress(output: Bool) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Whether the device has a mute switch at all. Most Bluetooth and USB outputs don't:
    /// AirPods, for one, expose volume but no settable mute.
    static func hasMute(_ id: AudioDeviceID, output: Bool) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var address = muteAddress(output: output)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(id, &address)
            && AudioObjectIsPropertySettable(id, &address, &settable) == noErr
            && settable.boolValue
    }

    static func muted(_ id: AudioDeviceID, output: Bool) -> Bool? {
        guard id != kAudioObjectUnknown else { return nil }
        var address = muteAddress(output: output)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    static func setMuted(_ muted: Bool, on id: AudioDeviceID, output: Bool) {
        guard id != kAudioObjectUnknown else { return }
        var address = muteAddress(output: output)
        guard hasMute(id, output: output) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Audio processes

    /// One entry per process Core Audio knows is *currently playing*. This is the list the
    /// per-app mixer is built from — no app needs to cooperate to appear in it.
    struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        /// Whether the process is putting sound out *right now*. Note that an app muted by
        /// one of our own taps stops reporting this — see `AudioService.refreshApps`.
        let isPlaying: Bool
    }

    /// Every process Core Audio knows about that has a pid, whether or not it is currently
    /// making sound. The caller decides which ones matter: filtering to "playing" here
    /// would hide exactly the apps we have muted ourselves.
    static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard let pid = processPID(id) else { return nil }
            return AudioProcess(objectID: id, pid: pid, isPlaying: isRunningOutput(id))
        }
    }

    static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    static func processPID(_ id: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr, pid > 0
        else { return nil }
        return pid
    }
}
