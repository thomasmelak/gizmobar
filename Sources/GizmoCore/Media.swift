import Foundation

/// How the now playing visualizer draws.
public enum VisualizerStyle: String, Sendable, Codable, CaseIterable {
    /// The spectrum leaves a trail of ridges sliding back into depth,
    /// mirrored with the bass in the middle.
    case ridgeline
    /// Classic cava bars, flat.
    case bars
    /// No visualizer.
    case off
}

/// `[media]` in config.toml.
public struct MediaSettings: Sendable, Equatable, Decodable {
    /// Folder holding `mediaremote-adapter.pl` and `MediaRemoteAdapter.framework`
    /// (github.com/ungive/mediaremote-adapter). With it, any app that plays
    /// media (browsers, podcasts) shows up; without it only Spotify and Music,
    /// plus `nowplaying-cli` when installed.
    public var adapter: String?
    /// Live spectrum from a Core Audio tap (asks for audio capture once).
    /// Off, or when permission is denied, the bars animate on their own.
    public var spectrum: Bool
    /// Bars in the spectrum.
    public var bands: Int
    /// Width of the track text on the bar, in points.
    public var width: Double
    /// How the visualizer draws: `ridgeline` (3D ridges, the default),
    /// `bars` (flat cava bars) or `off`.
    public var visualizer: VisualizerStyle

    public init(adapter: String? = nil, spectrum: Bool = true, bands: Int = 24, width: Double = 156,
                visualizer: VisualizerStyle = .ridgeline) {
        self.adapter = adapter
        self.spectrum = spectrum
        self.bands = bands
        self.width = width
        self.visualizer = visualizer
    }

    enum CodingKeys: String, CodingKey { case adapter, spectrum, bands, width, visualizer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MediaSettings()
        adapter = try c.decodeIfPresent(String.self, forKey: .adapter) ?? d.adapter
        spectrum = try c.decodeIfPresent(Bool.self, forKey: .spectrum) ?? d.spectrum
        bands = min(max(try c.decodeIfPresent(Int.self, forKey: .bands) ?? d.bands, 4), 64)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        let style = try c.decodeIfPresent(String.self, forKey: .visualizer)
        visualizer = style.flatMap { VisualizerStyle(rawValue: $0.lowercased()) } ?? d.visualizer
    }
}

public struct MediaTrack: Sendable, Equatable, Codable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds.
    public var duration: Double?
    /// Position in seconds at `elapsedAt`.
    public var elapsed: Double?
    public var elapsedAt: Date?
    /// Cached artwork file and the color picked from it.
    public var artworkPath: String?
    public var artColor: String?

    public init(title: String, artist: String = "", album: String = "", duration: Double? = nil,
                elapsed: Double? = nil, elapsedAt: Date? = nil, artworkPath: String? = nil, artColor: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.elapsedAt = elapsedAt
        self.artworkPath = artworkPath
        self.artColor = artColor
    }

    /// Identifies the track for crossfades and art caching.
    public var key: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    /// "Title · Artist", or the title alone.
    public var line: String { artist.isEmpty ? title : "\(title) · \(artist)" }
}

public struct MediaSource: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Codable { case playing, paused, stopped }
    public enum Repeat: String, Sendable, Codable { case off, one, all }

    /// The player's bundle ID.
    public var id: String
    public var name: String
    public var state: State
    public var track: MediaTrack?
    public var shuffle: Bool?
    public var repeatMode: Repeat?

    public init(id: String, name: String, state: State, track: MediaTrack? = nil, shuffle: Bool? = nil, repeatMode: Repeat? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.track = track
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }

    public var isPlaying: Bool { state == .playing }

    /// Position now, moving on from the last report while playing.
    public func position(at date: Date = Date()) -> Double? {
        guard let t = track, let e = t.elapsed else { return nil }
        guard isPlaying, let at = t.elapsedAt else { return e }
        let p = e + date.timeIntervalSince(at)
        return t.duration.map { min(p, $0) } ?? p
    }
}

public struct NowPlayingStatus: Sendable, Equatable, Codable {
    public var sources: [MediaSource]
    public var selected: String?

    public init(sources: [MediaSource] = [], selected: String? = nil) {
        self.sources = sources
        self.selected = selected
    }

    /// What the bar shows: the selected source while it has a track.
    public var current: MediaSource? {
        sources.first { $0.id == selected && $0.track != nil }
    }

    /// Picks the source to show. A source you picked stays while it has a
    /// track; otherwise the first playing one, then the first with a track.
    public static func choose(_ sources: [MediaSource], picked: String?) -> String? {
        let withTrack = sources.filter { $0.track != nil && $0.state != .stopped }
        if let picked, withTrack.contains(where: { $0.id == picked }) { return picked }
        return withTrack.first(where: \.isPlaying)?.id ?? withTrack.first?.id
    }
}

/// Picks a color from album art: the most common saturated color, nudged
/// light enough to read on the dark glass.
public enum ArtColor {
    /// `pixels` is RGBA, 8 bits per channel, row after row.
    public static func dominant(rgba pixels: [UInt8]) -> RGBA? {
        var buckets: [Int: (count: Double, r: Double, g: Double, b: Double)] = [:]
        var i = 0
        while i + 3 < pixels.count {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let a = Double(pixels[i + 3]) / 255
            i += 4
            guard a > 0.5 else { continue }
            let hsl = HSL(r: r, g: g, b: b)
            // Skip near-black, near-white and grey: they make poor accents.
            guard hsl.l > 0.12, hsl.l < 0.92, hsl.s > 0.2 else { continue }
            let key = Int(r * 7.99) << 6 | Int(g * 7.99) << 3 | Int(b * 7.99)
            let weight = 0.5 + hsl.s
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.count += weight; e.r += r * weight; e.g += g * weight; e.b += b * weight
            buckets[key] = e
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        return RGBA(r: best.r / best.count, g: best.g / best.count, b: best.b / best.count)
    }

    /// Raises lightness to at least `minLightness` and keeps the hue.
    public static func readable(_ c: RGBA, minLightness: Double = 0.6) -> RGBA {
        var hsl = HSL(r: c.r, g: c.g, b: c.b)
        hsl.l = max(hsl.l, minLightness)
        hsl.s = min(hsl.s, 0.85)
        return hsl.rgba
    }

    public static func hex(_ c: RGBA) -> String {
        func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + h(c.r) + h(c.g) + h(c.b)
    }
}

struct HSL {
    var h, s, l: Double

    init(r: Double, g: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        l = (mx + mn) / 2
        let d = mx - mn
        if d == 0 { h = 0; s = 0; return }
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
    }

    var rgba: RGBA {
        if s == 0 { return RGBA(r: l, g: l, b: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return RGBA(r: f(h + 1 / 3), g: f(h), b: f(h - 1 / 3))
    }
}

/// Turns FFT power into bar heights.
public enum Spectrum {
    /// Groups `power` (|X|² for bins 0..<n, n = fftSize/2) into `count`
    /// log-spaced bands between `low` and `high` Hz, as 0...1 on a dB scale
    /// from `floor` to `ceiling`.
    public static func bands(power: [Float], sampleRate: Double, count: Int,
                             low: Double = 40, high: Double = 16_000,
                             floor: Float = -70, ceiling: Float = -10) -> [Float] {
        guard power.count > 1, count > 0 else { return [] }
        let binHz = sampleRate / Double(power.count * 2)
        let ratio = pow(high / low, 1 / Double(count))
        var out = [Float](repeating: 0, count: count)
        let norm = Float(power.count * power.count)
        for i in 0..<count {
            let f0 = low * pow(ratio, Double(i)), f1 = f0 * ratio
            let b0 = max(1, Int(f0 / binHz)), b1 = min(power.count - 1, max(b0, Int(f1 / binHz)))
            var peak: Float = 0
            if b0 <= b1 { for b in b0...b1 { peak = max(peak, power[b]) } }
            let db = 10 * log10(max(peak / norm, 1e-12))
            out[i] = min(max((db - floor) / (ceiling - floor), 0), 1)
        }
        return out
    }

    /// Fast rise, slow fall, so bars read as motion and not flicker.
    public static func smooth(_ previous: [Float], _ next: [Float], attack: Float = 0.6, decay: Float = 0.15) -> [Float] {
        guard previous.count == next.count else { return next }
        return zip(previous, next).map { p, n in n > p ? p + (n - p) * attack : p + (n - p) * decay }
    }
}
