#if canImport(AppKit)
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import GizmoCore

/// Live spectrum of what the Mac is playing, from a Core Audio process tap
/// (macOS 14.2+). Runs only while something plays; the app starts and stops
/// it. Publishes band levels at up to 30 Hz. When the tap can't start (older
/// macOS, permission denied) it publishes nothing and the bar animates its
/// bars on its own.
public actor SpectrumProvider: Provider {
    public nonisolated let id = "spectrum"
    private var bus: EventBus?
    private var tap: AnyObject?
    private var bands: Int
    private var enabled: Bool
    private var failed = false

    public init(settings: MediaSettings) {
        bands = settings.bands
        enabled = settings.spectrum
    }

    public func start(bus: EventBus) async { self.bus = bus }

    public func stop() async { setRunning(false) }

    public func update(settings: MediaSettings) {
        let restart = tap != nil && (settings.bands != bands || !settings.spectrum)
        bands = settings.bands
        enabled = settings.spectrum
        if restart { setRunning(false) }
    }

    /// Starts the tap while playing, stops it otherwise.
    public func setRunning(_ on: Bool) {
        if on, enabled, !failed, tap == nil {
            guard #available(macOS 14.2, *) else { failed = true; return }
            let bus = self.bus
            let t = AudioTap(bands: bands) { levels in
                Task { await bus?.publish(topic: Topic.spectrum, payload: .array(levels.map { .number(Double($0)) })) }
            }
            do {
                try t.start()
                tap = t
            } catch {
                failed = true
                NSLog("gizmobar: audio tap unavailable, using animated bars: \(error)")
            }
        } else if !on, let t = tap {
            if #available(macOS 14.2, *) { (t as? AudioTap)?.stop() }
            tap = nil
            let bus = self.bus
            Task { await bus?.publish(topic: Topic.spectrum, payload: .array([])) }
        }
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

    init(bands: Int, publish: @escaping @Sendable ([Float]) -> Void) {
        analyzer = SpectrumAnalyzer(bands: bands, publish: publish)
    }

    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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
    private let bands: Int
    private let publish: @Sendable ([Float]) -> Void
    private let setup: FFTSetup
    private var window: [Float]
    private var samples: [Float] = []
    private var levels: [Float]
    private var sampleRate: Double = 48_000
    private var channels = 2
    private var interleaved = true
    private var lastPublish: UInt64 = 0

    init(bands: Int, publish: @escaping @Sendable ([Float]) -> Void) {
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
        if interleaved {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += floats[f * channels + c] }
                samples.append(sum / Float(channels))
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: frames))
        }
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
