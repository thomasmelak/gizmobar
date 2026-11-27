import Accelerate
import Foundation
import GizmoCore

/// Turns raw audio into bar heights the way cava (github.com/karlstav/cava)
/// does: two FFT sizes (a long one for the bass, a short one above it),
/// log-spaced bars, an equalizer that keeps the top end from looking empty,
/// automatic sensitivity, gravity on the way down and integral smoothing.
/// Pulled once per drawn frame from `AudioFrameHub`; not thread-safe, so
/// keep one per view.
public final class CavaAnalyzer {
    public struct Settings: Sendable, Equatable {
        public var bars: Int
        public var lowHz: Double = 50
        public var highHz: Double = 10_000
        /// Bars whose top edge is at or below this use the long FFT.
        public var bassCutoffHz: Double = 500
        /// cava's `noise_reduction`: 0 is jumpy, 1 is very smooth. Tuned for 60 fps.
        public var noiseReduction: Float = 0.77
        public var autoSensitivity = true

        public init(bars: Int) { self.bars = max(bars, 1) }
    }

    public let settings: Settings
    /// Heights, 0...1, one per bar.
    public private(set) var bars: [Float]
    /// The sensitivity auto-sens settled on (starts at 1).
    public private(set) var sensitivity: Float = 1

    private var sensInit = true
    private var mem: [Float]
    private var peak: [Float]
    private var fall: [Float]
    private var prev: [Float]
    private var raw: [Float]

    private var sampleRate: Double = 0
    private var bass: FFT?
    private var treble: FFT?
    private var plan: [(useBass: Bool, lo: Int, hi: Int, eq: Float)] = []
    private var window: [Float] = []
    private var lastWritten: UInt64?
    private var staleFor: Double = 0
    private var fake: [Float] = []

    public init(settings: Settings) {
        self.settings = settings
        let n = settings.bars
        bars = .init(repeating: 0, count: n)
        mem = bars; peak = bars; fall = bars; prev = bars; raw = bars
    }

    public convenience init(bars: Int) { self.init(settings: Settings(bars: bars)) }

    /// True once every bar has fallen to (almost) nothing.
    public var isSettled: Bool { bars.allSatisfy { $0 < 0.002 } }

    /// Advances by `dt` seconds with the newest audio of `source`. When the
    /// source isn't sending audio (no tap, or it stopped), bars fall under
    /// gravity; with `fakeWhenMissing` they ease around random heights
    /// instead, as the old bars did when the tap was unavailable.
    public func update(source: String?, playing: Bool, dt: Double, hub: AudioFrameHub = .shared, fakeWhenMissing: Bool = false) {
        let fps = Float(1 / max(dt, 1.0 / 240))
        guard playing, let source else {
            process(silenceFps: fps)
            return
        }
        let sr = hub.source(source)?.sampleRate ?? 0
        if sr > 0, sr != sampleRate { configure(sampleRate: sr) }
        if let bass, sampleRate > 0, let w = hub.read(source: source, into: &window) {
            // Nothing new for a while: the tap stopped. Don't loop on the
            // last window.
            if w.written == lastWritten { staleFor += dt } else { staleFor = 0 }
            lastWritten = w.written
            if staleFor < 0.25 {
                analyze(bass: bass)
                process(fps: fps)
                return
            }
        }
        if fakeWhenMissing {
            fakeStep(dt: dt)
            bars = fake
        } else {
            process(silenceFps: fps)
        }
    }

    /// Runs one frame on `samples` (mono, newest last, at least the long
    /// FFT's length). For tests and offline use.
    public func process(samples: [Float], sampleRate sr: Double, fps: Float) {
        if sr != sampleRate { configure(sampleRate: sr) }
        guard let bass else { return }
        let n = window.count
        if samples.count >= n {
            window = Array(samples.suffix(n))
        } else {
            window = [Float](repeating: 0, count: n - samples.count) + samples
        }
        analyze(bass: bass)
        process(fps: fps)
    }

    // MARK: Setup

    /// FFT sizes follow the sample rate so the bins keep their width in Hz.
    private func configure(sampleRate sr: Double) {
        sampleRate = sr
        let trebleSize = sr > 64_000 ? 2048 : (sr > 32_000 ? 1024 : 512)
        let bassSize = trebleSize * 4
        bass = FFT(size: bassSize)
        treble = FFT(size: trebleSize)
        window = [Float](repeating: 0, count: min(bassSize, AudioFrameHub.capacity))
        plan = Self.plan(settings: settings, sampleRate: sr, bassSize: bassSize, trebleSize: trebleSize)
        lastWritten = nil
    }

    /// Bin ranges per bar. Edges are log-spaced; each bar gets at least one
    /// bin of its own, as in cava.
    static func plan(settings s: Settings, sampleRate sr: Double, bassSize: Int, trebleSize: Int) -> [(useBass: Bool, lo: Int, hi: Int, eq: Float)] {
        let n = s.bars
        var out: [(Bool, Int, Int, Float)] = []
        var lastHi = (bass: 0, treble: 0)
        for i in 0..<n {
            let f0 = s.lowHz * pow(s.highHz / s.lowHz, Double(i) / Double(n))
            let f1 = s.lowHz * pow(s.highHz / s.lowHz, Double(i + 1) / Double(n))
            let useBass = f1 <= s.bassCutoffHz
            let size = useBass ? bassSize : trebleSize
            let binHz = sr / Double(size)
            let maxBin = size / 2 - 1
            var lo = max(1, Int(f0 / binHz))
            var hi = max(lo, Int(ceil(f1 / binHz)) - 1)
            let prevHi = useBass ? lastHi.bass : lastHi.treble
            if lo <= prevHi { lo = prevHi + 1 }
            lo = min(lo, maxBin)
            hi = min(max(hi, lo), maxBin)
            if useBass { lastHi.bass = hi } else { lastHi.treble = hi }
            // Music falls off about 3 dB an octave; lift the top to match.
            let eq = Float(sqrt(sqrt(f0 * f1) / 1000))
            out.append((useBass, lo, hi, eq))
        }
        return out
    }

    // MARK: Per frame

    private func analyze(bass: FFT) {
        let tail = treble.map { Array(window.suffix($0.size)) }
        let bassMag = bass.magnitudes(window)
        let trebleMag = treble?.magnitudes(tail ?? []) ?? []
        for (i, p) in plan.enumerated() {
            let mag = p.useBass ? bassMag : trebleMag
            guard p.hi < mag.count else { raw[i] = 0; continue }
            var sum: Float = 0
            for b in p.lo...p.hi { sum += mag[b] }
            raw[i] = sum / Float(p.hi - p.lo + 1) * p.eq
        }
    }

    private func process(silenceFps fps: Float) {
        for i in raw.indices { raw[i] = 0 }
        process(fps: fps)
    }

    /// cava's smoothing: sensitivity, gravity, integral, auto-sens.
    private func process(fps: Float) {
        let fps = max(fps, 1)
        let nr = pow(settings.noiseReduction, 60 / fps)
        let gravity = pow(60 / fps, 2.5) * 1.54 / max(settings.noiseReduction, 0.01)
        var overshoot = false
        var silence = true
        for i in bars.indices {
            if raw[i] > 1e-7 { silence = false }
            var v = raw[i] * sensitivity
            if v < prev[i] {
                v = max(0, peak[i] * (1 - fall[i] * fall[i] * gravity))
                fall[i] += 0.028
            } else {
                peak[i] = v
                fall[i] = 0
            }
            prev[i] = v
            v = mem[i] * nr + v
            mem[i] = v
            if v > 1 { overshoot = true }
            bars[i] = min(v, 1)
        }
        guard settings.autoSensitivity else { return }
        if overshoot {
            sensitivity *= 0.98
            sensInit = false
        } else if !silence {
            sensitivity *= 1.001
            if sensInit { sensitivity *= 1.1 }
        }
    }

    /// Eases toward random targets; middle bars reach higher.
    private func fakeStep(dt: Double) {
        let n = settings.bars
        if fake.count != n { fake = .init(repeating: 0, count: n) }
        let mid = Float(n) / 2
        let k = Float(min(1, dt * 8))
        for i in 0..<n {
            let reach = 0.45 + 0.5 * (1 - abs(Float(i) - mid) / mid)
            fake[i] += (Float.random(in: 0...reach) - fake[i]) * k
        }
    }
}

/// Smooths across neighbours so peaks read as hills (cava's monstercat).
public enum Monstercat {
    public static func apply(_ bars: [Float], strength: Float = 1.5) -> [Float] {
        var out = bars
        let n = bars.count
        for z in 0..<n where bars[z] > 0 {
            var d: Float = 1
            var m = z - 1
            while m >= 0 {
                d *= strength
                let v = bars[z] / d
                if v < 0.001 { break }
                out[m] = max(out[m], v)
                m -= 1
            }
            d = 1
            m = z + 1
            while m < n {
                d *= strength
                let v = bars[z] / d
                if v < 0.001 { break }
                out[m] = max(out[m], v)
                m += 1
            }
        }
        return out
    }
}

/// A real FFT with a Hann window, returning |X| per bin, scaled by size.
final class FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var hann: [Float]
    private var windowed: [Float]
    private var re: [Float]
    private var im: [Float]
    private var mag: [Float]

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = hann
        re = [Float](repeating: 0, count: size / 2)
        im = re
        mag = re
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(_ samples: [Float]) -> [Float] {
        guard samples.count >= size else { return [Float](repeating: 0, count: size / 2) }
        let half = size / 2
        samples.withUnsafeBufferPointer { s in
            vDSP_vmul(s.baseAddress! + (samples.count - size), 1, hann, 1, &windowed, 1, vDSP_Length(size))
        }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0 // packed Nyquist
                mag.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        var scale = 1 / Float(size)
        vDSP_vsmul(mag, 1, &scale, &mag, 1, vDSP_Length(half))
        return mag
    }
}
