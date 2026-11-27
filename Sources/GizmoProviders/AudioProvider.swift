#if canImport(CoreAudio)
import AudioToolbox
import CoreAudio
import Foundation
import GizmoCore

/// Output volume, mute and devices through Core Audio property listeners:
/// push only, no osascript or SwitchAudioSource.
public actor AudioProvider: Provider {
    public nonisolated let id = "audio"
    private var bus: EventBus?
    private var watchedDevice: AudioObjectID = 0
    private let queue = DispatchQueue(label: "gizmobar.audio")
    private var deviceListener: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start(bus: EventBus) async {
        self.bus = bus
        let system = AudioObjectID(kAudioObjectSystemObject)
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { await self?.systemChanged() }
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(system, &address, queue, changed)
        }
        await systemChanged()
    }

    public func stop() async {
        unwatch()
    }

    private func systemChanged() async {
        let device = Self.defaultOutput()
        if device != watchedDevice {
            unwatch()
            watch(device)
        }
        await publish()
    }

    private func watch(_ device: AudioObjectID) {
        guard device != 0 else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { await self?.publish() }
        }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        }
        watchedDevice = device
        deviceListener = listener
    }

    private func unwatch() {
        guard watchedDevice != 0, let listener = deviceListener else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &address, queue, listener)
        }
        watchedDevice = 0
        deviceListener = nil
    }

    func publish() async {
        await bus?.publish(topic: Topic.audio, payload: JSONValue(encoding: Self.status()))
    }

    // MARK: Actions

    /// Sets the volume (0...1) and unmutes, like the SketchyBar slider.
    public func setVolume(_ value: Double) async {
        let device = Self.defaultOutput()
        var v = Float32(min(max(value, 0), 1))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        Self.setMute(device, false)
        await publish()
    }

    public func toggleMute() async {
        let device = Self.defaultOutput()
        Self.setMute(device, !(Self.isMuted(device)))
        await publish()
    }

    public func select(_ id: UInt32) async {
        var device = AudioObjectID(id)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &device)
        await systemChanged()
    }

    // MARK: Reading

    static func status() -> AudioStatus {
        let current = defaultOutput()
        return AudioStatus(
            volume: Int((volume(current) * 100).rounded()),
            muted: isMuted(current),
            devices: outputDevices().map { AudioDevice(id: $0.id, name: $0.name, isCurrent: $0.id == current) }
        )
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioObjectID {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    static func volume(_ device: AudioObjectID) -> Double {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &v) == noErr else { return 0 }
        return Double(v)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &m) == noErr else { return false }
        return m != 0
    }

    static func setMute(_ device: AudioObjectID, _ muted: Bool) {
        var m = UInt32(muted ? 1 : 0)
        var address = address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    /// Devices with at least one output stream.
    static func outputDevices() -> [(id: AudioObjectID, name: String)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams)
            var streamSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = Self.address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let cf = name?.takeRetainedValue() else { return nil }
            return (id, cf as String)
        }
    }
}
#endif
