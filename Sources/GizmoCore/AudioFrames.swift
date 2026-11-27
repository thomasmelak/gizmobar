import Foundation

/// Live audio for visualizers, one ring of mono PCM per source. Capture code
/// writes from any thread; a visualizer reads the latest window once per
/// drawn frame and does its own analysis. Audio never goes through the
/// EventBus or `BarSnapshot`, so it doesn't re-render SwiftUI.
public final class AudioFrameHub: @unchecked Sendable {
    public static let shared = AudioFrameHub()

    /// Source id for the whole-system mix (the global tap).
    public static let system = "system"
    /// Samples kept per source.
    public static let capacity = 8192
    /// RMS below this counts as silence (about -80 dB).
    public static let silence: Float = 1e-4

    /// A source heard recently, for lists and pickers.
    public struct Source: Sendable, Equatable, Identifiable {
        /// Bundle id, the same as `MediaSource.id`, or `AudioFrameHub.system`.
        public var id: String
        /// RMS of the last chunk written, 0...1.
        public var level: Float
        /// Peak of the last chunk written, 0...1.
        public var peak: Float
        public var sampleRate: Double
        /// Last time the source was above silence.
        public var lastHeard: Date
        /// Last time anything was written, silent or not.
        public var lastWrite: Date

        /// Above silence within the last `window` seconds.
        public func isActive(at date: Date = Date(), window: TimeInterval = 0.5) -> Bool {
            date.timeIntervalSince(lastHeard) < window
        }
    }

    /// A read window: the latest samples, oldest first.
    public struct Window: Sendable {
        public var sampleRate: Double
        /// Samples ever written to this source. The difference between two
        /// reads is how many new samples arrived in between.
        public var written: UInt64
    }

    private final class Ring {
        var samples = [Float](repeating: 0, count: AudioFrameHub.capacity)
        var head = 0
        var written: UInt64 = 0
        var info: Source

        init(id: String, sampleRate: Double, now: Date) {
            info = Source(id: id, level: 0, peak: 0, sampleRate: sampleRate, lastHeard: .distantPast, lastWrite: now)
        }
    }

    private let lock = NSLock()
    private var rings: [String: Ring] = [:]

    public init() {}

    /// Appends mono float PCM for `source`. Any chunk size, any thread.
    public func write(source: String, samples: UnsafeBufferPointer<Float>, sampleRate: Double, at now: Date = Date()) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        var peak: Float = 0
        for s in samples {
            sum += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sum / Float(samples.count)).squareRoot()

        lock.lock()
        defer { lock.unlock() }
        let ring: Ring
        if let r = rings[source] { ring = r } else {
            ring = Ring(id: source, sampleRate: sampleRate, now: now)
            rings[source] = ring
        }
        let cap = Self.capacity
        // Only the newest `cap` samples of an oversized chunk matter.
        let tail = samples.count > cap ? UnsafeBufferPointer(rebasing: samples[(samples.count - cap)...]) : samples
        ring.samples.withUnsafeMutableBufferPointer { buf in
            var i = ring.head
            for s in tail {
                buf[i] = s
                i += 1
                if i == cap { i = 0 }
            }
            ring.head = i
        }
        ring.written &+= UInt64(samples.count)
        ring.info.level = min(rms, 1)
        ring.info.peak = min(peak, 1)
        ring.info.sampleRate = sampleRate
        ring.info.lastWrite = now
        if rms > Self.silence { ring.info.lastHeard = now }
    }

    /// Convenience for arrays.
    public func write(source: String, samples: [Float], sampleRate: Double, at now: Date = Date()) {
        samples.withUnsafeBufferPointer { write(source: source, samples: $0, sampleRate: sampleRate, at: now) }
    }

    /// Copies the latest `into.count` samples of `source` (up to `capacity`),
    /// oldest first. Nil when nothing was ever written for it.
    @discardableResult
    public func read(source: String, into out: inout [Float]) -> Window? {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = rings[source] else { return nil }
        let cap = Self.capacity
        let n = min(out.count, cap)
        // Front-pad when the caller wants more than we have.
        let pad = out.count - n
        ring.samples.withUnsafeBufferPointer { buf in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<pad { dst[i] = 0 }
                var j = ring.head - n
                if j < 0 { j += cap }
                for i in 0..<n {
                    dst[pad + i] = buf[j]
                    j += 1
                    if j == cap { j = 0 }
                }
            }
        }
        return Window(sampleRate: ring.info.sampleRate, written: ring.written)
    }

    /// The current info for one source.
    public func source(_ id: String) -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return rings[id]?.info
    }

    /// Sources written to within the last `within` seconds, most recently
    /// heard first. Quiet sources stay listed until `within` runs out.
    public func sources(within: TimeInterval = 300, at now: Date = Date()) -> [Source] {
        lock.lock()
        let all = rings.values.map(\.info)
        lock.unlock()
        return all
            .filter { now.timeIntervalSince($0.lastWrite) < within }
            .sorted { ($0.lastHeard, $0.id) > ($1.lastHeard, $1.id) }
    }

    /// Every source written to in the last five minutes.
    public var sources: [Source] { sources() }

    /// Forgets a source (e.g. its app quit).
    public func remove(source: String) {
        lock.lock()
        rings[source] = nil
        lock.unlock()
    }
}
