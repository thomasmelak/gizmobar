#if canImport(AppKit)
import Accelerate
import AudioToolbox
import CoreAudio
import AppKit
import Foundation
import GizmoCore

/// Every app that makes sound, each heard on its own: Core Audio process
/// taps (macOS 14.2+), one per app, so a call, a video and music each get
/// their own levels. Helper processes (a browser's audio service, Zoom's
/// call host) count as their app. Lists apps playing now and heard in the
/// last 10 minutes on `audio.sources`, and publishes each active app's
/// levels on `media.spectrum`. Raw samples go to `AudioFrameHub` and never
/// onto the bus. Runs only while the bar shows now playing.
public actor SpectrumProvider: Provider {
    public nonisolated let id = "spectrum"
    private var bus: EventBus?
    private var bands: Int
    private var enabled: Bool
    private var running = false
    private var unsupported = false
    private var loop: Task<Void, Never>?
    /// Taps by app bundle ID.
    private var taps: [String: AnyObject] = [:]
    private var tapProcesses: [String: Set<AudioObjectID>] = [:]
    private var retryAfter: [String: Date] = [:]
    private var known: [String: AudioSource] = [:]
    private var lastPublished: [AudioSource] = []

    /// Taps stay open this long after an app goes quiet, so short pauses
    /// don't rebuild them.
    static let linger: TimeInterval = 15

    public init(settings: MediaSettings) {
        bands = settings.bands
        enabled = settings.spectrum
    }

    public func start(bus: EventBus) async { self.bus = bus }

    public func stop() async { setRunning(false) }

    public func update(settings: MediaSettings) {
        let changed = settings.bands != bands || settings.spectrum != enabled
        bands = settings.bands
        enabled = settings.spectrum
        if changed, running { setRunning(false); setRunning(true) }
    }

    /// Watches audio while the bar shows now playing.
    public func setRunning(_ on: Bool) {
        let on = on && enabled
        guard on != running else { return }
        running = on
        if on {
            guard #available(macOS 14.2, *) else { unsupported = true; return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.scan()
                    try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200))
                }
            }
        } else {
            loop?.cancel()
            loop = nil
            for id in Array(taps.keys) { closeTap(id) }
            known = [:]
            Task { await publishSources() }
        }
    }

    // MARK: Scanning

    @available(macOS 14.2, *)
    private func scan() async {
        let processes = AudioProcesses.list()
        let apps = await MainActor.run { AppGrouping.snapshot() }
        let now = Date()

        // Group the processes making sound by app.
        var active: [String: Set<AudioObjectID>] = [:]
        for p in processes where p.isRunningOutput {
            guard let app = apps.app(forBundleID: p.bundleID, pid: p.pid) else { continue }
            active[app, default: []].insert(p.object)
        }

        for (id, objects) in active {
            known[id] = AudioSource(id: id, name: apps.name(id), isActive: true, lastHeard: now)
            if tapProcesses[id] != objects { openTap(id, objects) }
        }
        for (id, var s) in known where active[id] == nil {
            s.isActive = false
            known[id] = s
            if taps[id] != nil, now.timeIntervalSince(s.lastHeard) > Self.linger { closeTap(id) }
        }
        known = known.filter { $0.value.isActive || now.timeIntervalSince($0.value.lastHeard) <= 600 }
        await publishSources()
    }

    @available(macOS 14.2, *)
    private func openTap(_ id: String, _ objects: Set<AudioObjectID>) {
        if let until = retryAfter[id], until > Date() { return }
        closeTap(id)
        let bus = self.bus
        let t = AudioTap(source: id, processes: Array(objects), bands: bands) { levels in
            Task { await bus?.publish(topic: Topic.spectrum, key: id, payload: JSONValue(encoding: SourceSpectrum(source: id, levels: levels))) }
        }
        do {
            try t.start()
            taps[id] = t
            tapProcesses[id] = objects
            retryAfter[id] = nil
        } catch {
            retryAfter[id] = Date().addingTimeInterval(30)
            NSLog("gizmobar: audio tap for \(id) unavailable, using animated bars: \(error)")
        }
    }

    private func closeTap(_ id: String) {
        if #available(macOS 14.2, *), let t = taps[id] as? AudioTap { t.stop() }
        taps[id] = nil
        tapProcesses[id] = nil
        let bus = self.bus
        Task { await bus?.publish(topic: Topic.spectrum, key: id, payload: JSONValue(encoding: SourceSpectrum(source: id, levels: []))) }
    }

    private func publishSources() async {
        let list = AudioSourcesStatus.ordered(Array(known.values))
        // lastHeard ticks every scan while active; publish on real changes
        // and at most every 10 s otherwise.
        let shape = { (l: [AudioSource]) in l.map { "\($0.id)\($0.isActive)" } }
        let stale = (lastPublished.first?.lastHeard).map { Date().timeIntervalSince($0) > 10 } ?? true
        guard shape(list) != shape(lastPublished) || stale else { return }
        lastPublished = list
        await bus?.publish(topic: Topic.audioSources, payload: JSONValue(encoding: AudioSourcesStatus(sources: list)))
    }
}

/// Core Audio's process objects (macOS 14.2+).
@available(macOS 14.2, *)
enum AudioProcesses {
    struct Process {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    static func list() -> [Process] {
        let objects: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { o in
            let pid: pid_t = scalar(o, kAudioProcessPropertyPID) ?? -1
            let running: UInt32 = scalar(o, kAudioProcessPropertyIsRunningOutput) ?? 0
            return Process(object: o, pid: pid, bundleID: string(o, kAudioProcessPropertyBundleID) ?? "", isRunningOutput: running != 0)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }
}

/// Maps audio processes to the apps people know: the process itself when
/// it's a regular app, else the app whose bundle ID prefixes the helper's
/// (com.google.Chrome.helper → Chrome), else the only running app from the
/// same vendor (us.zoom.CptHost → zoom.us). WebKit's audio service plays
/// for Safari.
struct AppGrouping: Sendable {
    private var apps: [(id: String, name: String, pid: pid_t)]
    private static let ownID = Bundle.main.bundleIdentifier ?? "io.thomasmelak.gizmobar"

    @MainActor static func snapshot() -> AppGrouping {
        AppGrouping(apps: NSWorkspace.shared.runningApplications.compactMap { a in
            guard a.activationPolicy == .regular, let id = a.bundleIdentifier, id != ownID else { return nil }
            return (id, a.localizedName ?? id, a.processIdentifier)
        })
    }

    init(apps: [(id: String, name: String, pid: pid_t)]) { self.apps = apps }

    func name(_ id: String) -> String { apps.first { $0.id == id }?.name ?? id }

    func app(forBundleID bundleID: String, pid: pid_t) -> String? {
        if let a = apps.first(where: { $0.pid == pid }) { return a.id }
        guard !bundleID.isEmpty, bundleID != Self.ownID else { return nil }
        if let a = apps.first(where: { $0.id == bundleID }) { return a.id }
        if let a = apps.filter({ bundleID.hasPrefix($0.id + ".") }).max(by: { $0.id.count < $1.id.count }) { return a.id }
        if bundleID.hasPrefix("com.apple.WebKit"), apps.contains(where: { $0.id == "com.apple.Safari" }) { return "com.apple.Safari" }
        let vendor = Self.vendor(bundleID)
        guard !vendor.isEmpty, vendor != "com.apple" else { return nil }
        let same = apps.filter { Self.vendor($0.id) == vendor }
        return same.count == 1 ? same[0].id : nil
    }

    static func vendor(_ id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

enum TapError: Error { case status(String, OSStatus) }

@available(macOS 14.2, *)
final class AudioTap: @unchecked Sendable {
    private let analyzer: SpectrumAnalyzer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "gizmobar.audiotap", qos: .userInitiated)

    private let processes: [AudioObjectID]

    init(source: String, processes: [AudioObjectID], bands: Int, publish: @escaping @Sendable ([Float]) -> Void) {
        self.processes = processes
        analyzer = SpectrumAnalyzer(source: source, bands: bands, publish: publish)
    }

    func start() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        try check("create tap", AudioHardwareCreateProcessTap(desc, &tapID))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Gizmobar Spectrum",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check("create aggregate", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check("tap format", AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format))
        analyzer.configure(sampleRate: format.mSampleRate,
                           channels: Int(format.mChannelsPerFrame),
                           interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)

        let analyzer = self.analyzer
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            analyzer.consume(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
    }

    deinit { stop() }

    private func check(_ what: String, _ status: OSStatus) throws {
        if status != noErr { throw TapError.status(what, status) }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.status("output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError.status("output uid", status) }
        return uid.takeRetainedValue() as String
    }
}

/// Mono mix → 1024-point FFT with a Hann window → bands. Used only on the
/// tap's IO queue.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let size = 1024
    private let log2n: vDSP_Length = 10
    private let source: String
    private let bands: Int
    private let publish: @Sendable ([Float]) -> Void
    private var mono: [Float] = []
    private let setup: FFTSetup
    private var window: [Float]
    private var samples: [Float] = []
    private var levels: [Float]
    private var sampleRate: Double = 48_000
    private var channels = 2
    private var interleaved = true
    private var lastPublish: UInt64 = 0

    init(source: String, bands: Int, publish: @escaping @Sendable ([Float]) -> Void) {
        self.source = source
        self.bands = bands
        self.publish = publish
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM))
        levels = [Float](repeating: 0, count: bands)
        samples.reserveCapacity(2048)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func configure(sampleRate: Double, channels: Int, interleaved: Bool) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channels = max(channels, 1)
        self.interleaved = interleaved
    }

    func consume(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        mono.removeAll(keepingCapacity: true)
        if interleaved {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += floats[f * channels + c] }
                mono.append(sum / Float(channels))
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            mono.append(contentsOf: UnsafeBufferPointer(start: floats, count: frames))
        }
        mono.withUnsafeBufferPointer { AudioFrameHub.shared.write(source: source, samples: $0, sampleRate: sampleRate) }
        samples.append(contentsOf: mono)
        guard samples.count >= size else { return }
        let chunk = Array(samples.suffix(size))
        samples.removeAll(keepingCapacity: true)

        // At most ~30 updates a second.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastPublish > 33_000_000 else { return }
        lastPublish = now

        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(chunk, 1, window, 1, &windowed, 1, vDSP_Length(size))
        var real = [Float](repeating: 0, count: size / 2)
        var imag = [Float](repeating: 0, count: size / 2)
        var power = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
            }
        }
        levels = Spectrum.smooth(levels, Spectrum.bands(power: power, sampleRate: sampleRate, count: bands))
        publish(levels)
    }
}
#endif
