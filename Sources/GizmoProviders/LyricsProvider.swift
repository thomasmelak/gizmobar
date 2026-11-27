import Foundation
import GizmoCore

/// Lyrics for the selected track from LRCLIB (lrclib.net): synced when it
/// has timings, plain otherwise. Looked up once per track and kept for the
/// session; nothing is published when none are found.
public actor LyricsProvider: Provider {
    public nonisolated let id = "lyrics"
    private var bus: EventBus?
    private var settings: LyricsSettings
    private var cache: [String: Lyrics?] = [:]
    private var current: String?
    private var watch: Task<Void, Never>?

    public init(settings: LyricsSettings) {
        self.settings = settings
    }

    public func start(bus: EventBus) async {
        self.bus = bus
        watch = Task { [weak self] in
            for await event in await bus.subscribe(prefixes: [Topic.media]) {
                guard let status = event.payload.decode(NowPlayingStatus.self) else { continue }
                await self?.mediaChanged(status.current?.track)
            }
        }
    }

    public func stop() async { watch?.cancel() }

    public func update(settings: LyricsSettings) async {
        self.settings = settings
        if !settings.enabled { await publish(nil) }
    }

    private func mediaChanged(_ track: MediaTrack?) async {
        guard settings.enabled else { return }
        guard let track else {
            if current != nil { current = nil; await publish(nil) }
            return
        }
        guard track.key != current else { return }
        current = track.key
        await publish(nil)
        let lyrics: Lyrics?
        if let cached = cache[track.key] {
            lyrics = cached
        } else {
            lyrics = await Self.fetch(track)
            cache[track.key] = lyrics
        }
        guard current == track.key else { return }
        await publish(lyrics)
    }

    private func publish(_ lyrics: Lyrics?) async {
        await bus?.publish(topic: Topic.lyrics, payload: lyrics.map { JSONValue(encoding: $0) } ?? .null)
    }

    static let base = "https://lrclib.net/api"

    /// Exact match on title, artist, album and length, then a search.
    static func fetch(_ t: MediaTrack) async -> Lyrics? {
        var get = URLComponents(string: base + "/get")!
        get.queryItems = [.init(name: "track_name", value: t.title), .init(name: "artist_name", value: t.artist)]
        if !t.album.isEmpty { get.queryItems?.append(.init(name: "album_name", value: t.album)) }
        if let d = t.duration { get.queryItems?.append(.init(name: "duration", value: String(Int(d.rounded())))) }
        if let json = await request(get.url) as? [String: Any], let l = lyrics(json, key: t.key) { return l }

        var search = URLComponents(string: base + "/search")!
        search.queryItems = [.init(name: "track_name", value: t.title), .init(name: "artist_name", value: t.artist)]
        guard let results = await request(search.url) as? [[String: Any]] else { return nil }
        // Prefer synced results with a close length.
        let ranked = results.sorted { a, b in
            func score(_ r: [String: Any]) -> Double {
                let synced = (r["syncedLyrics"] as? String).map { $0.isEmpty ? 0.0 : 1.0 } ?? 0
                let dd = abs((r["duration"] as? Double ?? 0) - (t.duration ?? 0))
                return synced * 10 - min(dd, 30) / 3
            }
            return score(a) > score(b)
        }
        for r in ranked.prefix(3) { if let l = lyrics(r, key: t.key) { return l } }
        return nil
    }

    static func lyrics(_ r: [String: Any], key: String) -> Lyrics? {
        if r["instrumental"] as? Bool == true { return Lyrics(key: key, lines: [], instrumental: true) }
        if let synced = r["syncedLyrics"] as? String, !synced.isEmpty {
            let lines = Lyrics.parseLRC(synced)
            if !lines.isEmpty { return Lyrics(key: key, lines: lines) }
        }
        if let plain = r["plainLyrics"] as? String, !plain.isEmpty {
            return Lyrics(key: key, lines: Lyrics.parsePlain(plain))
        }
        return nil
    }

    static func request(_ url: URL?) async -> Any? {
        guard let url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        // LRCLIB asks clients to identify themselves.
        req.setValue("Gizmobar (https://github.com/thomasmelak/gizmobar)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
