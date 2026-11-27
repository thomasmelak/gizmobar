#if canImport(AppKit)
import AppKit
import ImageIO
import GizmoCore

/// Now playing, from up to three kinds of source:
/// - Spotify and Music, read with AppleScript when they announce a change
///   (distributed notifications, so there's no polling);
/// - any other app through mediaremote-adapter when `[media] adapter` is
///   set (one long-running process streaming changes);
/// - otherwise `nowplaying-cli`, polled every 3 s, when it's installed.
/// Artwork is cached on disk and a color picked from it once per track.
public actor MediaProvider: Provider {
    public nonisolated let id = "media"
    private var bus: EventBus?
    private var settings: MediaSettings
    private var sources: [String: MediaSource] = [:]
    private var picked: String?
    private var observers: [NSObjectProtocol] = []
    private var adapter: Process?
    private var adapterState: [String: JSONValue] = [:]
    private var pollTask: Task<Void, Never>?
    private var lastArtKey: [String: String] = [:]
    private let scripts = ScriptRunner()

    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"

    public init(settings: MediaSettings) {
        self.settings = settings
    }

    public func start(bus: EventBus) async {
        self.bus = bus
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: nil) { [weak self] _ in
            Task { await self?.refreshPlayer(Self.spotify) }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: nil) { [weak self] _ in
            Task { await self?.refreshPlayer(Self.music) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            Task { await self?.remove(id) }
        })
        await refreshPlayer(Self.spotify)
        await refreshPlayer(Self.music)
        startGeneric()
    }

    public func stop() async {
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers = []
        adapter?.terminate()
        adapter = nil
        pollTask?.cancel()
    }

    public func update(settings: MediaSettings) {
        guard settings.adapter != self.settings.adapter else { self.settings = settings; return }
        self.settings = settings
        adapter?.terminate()
        adapter = nil
        pollTask?.cancel()
        startGeneric()
    }

    // MARK: Commands

    public enum Action: String, Sendable { case toggle, next, previous, shuffle, `repeat` }

    public func send(_ command: Action) async {
        guard let id = NowPlayingStatus.choose(Array(sources.values), picked: picked), let source = sources[id] else { return }
        switch id {
        case Self.spotify:
            let s: String
            switch command {
            case .toggle: s = "playpause"
            case .next: s = "next track"
            case .previous: s = "previous track"
            case .shuffle: s = "set shuffling to not shuffling"
            case .repeat: s = "set repeating to not repeating"
            }
            _ = await scripts.run("tell application \"Spotify\" to \(s)") { _ in true }
        case Self.music:
            let s: String
            switch command {
            case .toggle: s = "playpause"
            case .next: s = "next track"
            case .previous: s = "back track"
            case .shuffle: s = "set shuffle enabled to not shuffle enabled"
            case .repeat:
                let next: String = switch source.repeatMode ?? .off { case .off: "all"; case .all: "one"; case .one: "off" }
                s = "set song repeat to \(next)"
            }
            _ = await scripts.run("tell application \"Music\" to \(s)") { _ in true }
        default:
            switch command {
            case .toggle: await generic(adapterArgs: ["send", "2"], cli: ["togglePlayPause"])
            case .next: await generic(adapterArgs: ["send", "4"], cli: ["next"])
            case .previous: await generic(adapterArgs: ["send", "5"], cli: ["previous"])
            case .shuffle, .repeat: return
            }
            await pollOnce()
        }
        if id == Self.spotify || id == Self.music { await refreshPlayer(id) }
    }

    public func seek(_ seconds: Double) async {
        guard let id = NowPlayingStatus.choose(Array(sources.values), picked: picked) else { return }
        switch id {
        case Self.spotify:
            _ = await scripts.run("tell application \"Spotify\" to set player position to \(seconds)") { _ in true }
            await refreshPlayer(id)
        case Self.music:
            _ = await scripts.run("tell application \"Music\" to set player position to \(seconds)") { _ in true }
            await refreshPlayer(id)
        default:
            await generic(adapterArgs: ["seek", String(Int(seconds * 1_000_000))], cli: ["seek", String(seconds)])
            if var s = sources[id], s.track != nil {
                s.track?.elapsed = seconds
                s.track?.elapsedAt = Date()
                sources[id] = s
                await publish()
            }
        }
    }

    public func select(_ id: String) async {
        picked = id
        await publish()
    }

    // MARK: Spotify and Music

    private func refreshPlayer(_ id: String) async {
        let running = await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
        guard running else { return await remove(id) }
        let app = id == Self.spotify ? "Spotify" : "Music"
        let script = id == Self.spotify ? """
            tell application "Spotify"
              if player state is stopped then return {}
              set t to current track
              return {name of t, artist of t, album of t, player state as string, (duration of t) / 1000, player position, shuffling, repeating, artwork url of t}
            end tell
            """ : """
            tell application "Music"
              if player state is stopped then return {}
              set t to current track
              return {name of t, artist of t, album of t, player state as string, duration of t, player position, shuffle enabled, song repeat as string, ""}
            end tell
            """
        let fields: [String]? = await scripts.run(script) { d in
            guard d.numberOfItems >= 9 else { return [] }
            // stringValue coerces booleans to "true"/"false" and numbers to text.
            return (1...d.numberOfItems).map { d.atIndex($0)?.stringValue ?? "" }
        }
        guard let f = fields, f.count >= 9 else { return await remove(id) }
        let state: MediaSource.State = f[3] == "playing" ? .playing : (f[3] == "paused" ? .paused : .stopped)
        let repeatMode: MediaSource.Repeat = id == Self.spotify ? (f[7] == "true" ? .all : .off) : (MediaSource.Repeat(rawValue: f[7]) ?? .off)
        var track = MediaTrack(title: f[0], artist: f[1], album: f[2], duration: Double(f[4].replacingOccurrences(of: ",", with: ".")),
                               elapsed: Double(f[5].replacingOccurrences(of: ",", with: ".")), elapsedAt: Date())
        keepArt(&track, from: sources[id]?.track)
        sources[id] = MediaSource(id: id, name: app, state: state, track: track, shuffle: f[6] == "true", repeatMode: repeatMode)
        await publish()
        if track.artworkPath == nil {
            if id == Self.spotify, let url = URL(string: f[8]), !f[8].isEmpty {
                await loadArt(for: id, key: track.key) { try? await URLSession.shared.data(from: url).0 }
            } else if id == Self.music {
                let scripts = self.scripts
                await loadArt(for: id, key: track.key) {
                    await scripts.run("tell application \"Music\" to get raw data of artwork 1 of current track") { $0.data }
                }
            }
        }
    }

    // MARK: Other apps

    private func startGeneric() {
        if let dir = settings.adapter.map(GizmoPaths.expand),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("mediaremote-adapter.pl").path) {
            startAdapter(dir)
        } else if Self.cli != nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pollOnce()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private static var cli: String? {
        Command.which("nowplaying-cli", candidates: ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    private func adapterPaths() -> (script: String, framework: String)? {
        guard let dir = settings.adapter.map(GizmoPaths.expand) else { return nil }
        return (dir.appendingPathComponent("mediaremote-adapter.pl").path, dir.appendingPathComponent("MediaRemoteAdapter.framework").path)
    }

    private func startAdapter(_ dir: URL) {
        guard let paths = adapterPaths() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.framework, "stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let reader = LineReader()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            for line in reader.feed(data) {
                Task { await self?.adapterLine(line) }
            }
        }
        do {
            try p.run()
            adapter = p
        } catch {
            NSLog("gizmobar: mediaremote-adapter: \(error)")
        }
    }

    private func adapterLine(_ line: Data) async {
        guard let msg = try? JSONValue(parsing: line), msg["type"]?.string == "data",
              case .object(let payload)? = msg["payload"] else { return }
        let diff: Bool = { if case .bool(let b)? = msg["diff"] { return b }; return false }()
        if diff { adapterState.merge(payload) { $1 } } else { adapterState = payload }
        await applyGeneric(adapterState, art: { s in
            guard let b64 = s["artworkData"]?.string else { return nil }
            return Data(base64Encoded: b64)
        })
    }

    private func pollOnce() async {
        guard adapter == nil, let cli = Self.cli else { return }
        let keys = ["clientBundleIdentifier", "playbackRate", "title", "artist", "album", "duration", "elapsedTime"]
        guard let data = try? await Command.run(cli, ["get"] + keys),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var s: [String: JSONValue] = [:]
        for (k, v) in zip(keys, lines) where v != "null" && !v.isEmpty {
            s[k] = Double(v).map(JSONValue.number) ?? .string(v)
        }
        if let id = s["clientBundleIdentifier"]?.string { s["bundleIdentifier"] = .string(id) }
        if case .number(let rate)? = s["playbackRate"] { s["playing"] = .bool(rate > 0) }
        if case .number(let e)? = s["elapsedTime"] { s["elapsedTime"] = .number(e) }
        await applyGeneric(s, art: { _ in
            guard let d = try? await Command.run(cli, ["get", "artworkData"]),
                  let b64 = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return Data(base64Encoded: b64)
        })
    }

    private func applyGeneric(_ s: [String: JSONValue], art: @escaping @Sendable ([String: JSONValue]) async -> Data?) async {
        let previous = sources.values.first { $0.id != Self.spotify && $0.id != Self.music }
        guard let id = s["bundleIdentifier"]?.string ?? s["parentApplicationBundleIdentifier"]?.string,
              id != Self.spotify, id != Self.music, let title = s["title"]?.string, !title.isEmpty else {
            if let previous { await remove(previous.id) }
            return
        }
        if let previous, previous.id != id { sources[previous.id] = nil }
        func num(_ k: String) -> Double? { if case .number(let n)? = s[k] { return n }; return nil }
        let playing: Bool = { if case .bool(let b)? = s["playing"] { return b }; return false }()
        var track = MediaTrack(title: title, artist: s["artist"]?.string ?? "", album: s["album"]?.string ?? "",
                               duration: num("duration"), elapsed: num("elapsedTime"), elapsedAt: Date())
        keepArt(&track, from: sources[id]?.track)
        let name = await MainActor.run { Self.appName(id) }
        sources[id] = MediaSource(id: id, name: name, state: playing ? .playing : .paused, track: track)
        await publish()
        if track.artworkPath == nil {
            await loadArt(for: id, key: track.key) { await art(s) }
        }
    }

    @MainActor private static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func generic(adapterArgs: [String], cli: [String]) async {
        if let paths = adapterPaths(), adapter != nil {
            _ = try? await Command.run("/usr/bin/perl", [paths.script, paths.framework] + adapterArgs)
        } else if let c = Self.cli {
            _ = try? await Command.run(c, cli)
        }
    }

    // MARK: Artwork

    /// Keeps the art of the same track across refreshes.
    private func keepArt(_ track: inout MediaTrack, from old: MediaTrack?) {
        guard let old, old.key == track.key else { return }
        track.artworkPath = old.artworkPath
        track.artColor = old.artColor
    }

    private func loadArt(for id: String, key: String, _ fetch: @Sendable () async -> Data?) async {
        guard lastArtKey[id] != key else { return }
        lastArtKey[id] = key
        let file = Self.artDir.appendingPathComponent(String(format: "%016llx", fnv1a(key)))
        var color: String?
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let data = await fetch(), !data.isEmpty else { return }
            try? FileManager.default.createDirectory(at: Self.artDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        color = Self.color(of: file)
        guard var s = sources[id], s.track?.key == key else { return }
        s.track?.artworkPath = file.path
        s.track?.artColor = color
        sources[id] = s
        await publish()
    }

    private static var artDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gizmobar/art", isDirectory: true)
    }

    /// The art's main color, from a 32 px thumbnail.
    static func color(of file: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return nil }
        let w = thumb.width, h = thumb.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, let c = ArtColor.dominant(rgba: pixels) else { return nil }
        return ArtColor.hex(ArtColor.readable(c))
    }

    // MARK: State

    private func remove(_ id: String) async {
        guard sources[id] != nil else { return }
        sources[id] = nil
        lastArtKey[id] = nil
        await publish()
    }

    private func publish() async {
        let order = [Self.spotify, Self.music]
        let list = sources.values.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? 2, ib = order.firstIndex(of: b.id) ?? 2
            return ia != ib ? ia < ib : a.name < b.name
        }
        let status = NowPlayingStatus(sources: list, selected: NowPlayingStatus.choose(list, picked: picked))
        await bus?.publish(topic: Topic.media, payload: JSONValue(encoding: status))
    }
}

private func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// Runs AppleScript on one serial queue (NSAppleScript isn't thread safe)
/// and caches compiled scripts.
final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gizmobar.applescript")
    private var cache: [String: NSAppleScript] = [:]

    func run<T: Sendable>(_ source: String, _ transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        await withCheckedContinuation { cont in
            queue.async {
                let script = self.cache[source] ?? NSAppleScript(source: source)
                self.cache[source] = script
                var error: NSDictionary?
                guard let result = script?.executeAndReturnError(&error), error == nil else { return cont.resume(returning: nil) }
                cont.resume(returning: transform(result))
            }
        }
    }
}

/// Splits a byte stream into lines.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
#endif
