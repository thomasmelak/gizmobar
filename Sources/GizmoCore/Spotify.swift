import Foundation

/// `[spotify]` in config.toml. Signing in adds the up-next queue around the
/// album art and your playlists to the Now Playing popover. Needs a client
/// ID from an app at developer.spotify.com whose redirect URI is
/// `http://127.0.0.1:<port>/callback`.
public struct SpotifySettings: Sendable, Equatable, Decodable {
    public var clientID: String?
    /// Local port for the sign-in redirect.
    public var port: Int

    public init(clientID: String? = nil, port: Int = 43821) {
        self.clientID = clientID
        self.port = port
    }

    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }
    public var isConfigured: Bool { !(clientID ?? "").isEmpty }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id", port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpotifySettings()
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? d.clientID
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
    }
}

/// `[lyrics]` in config.toml: lyrics from LRCLIB (lrclib.net, free, no
/// account), synced to the track when it has timings. Looking them up
/// sends the track's title, artist, album and length to LRCLIB.
public struct LyricsSettings: Sendable, Equatable, Decodable {
    public var enabled: Bool

    public init(enabled: Bool = true) { self.enabled = enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    enum CodingKeys: String, CodingKey { case enabled }
}

public struct PlaylistRef: Sendable, Equatable, Codable, Identifiable {
    public var name: String
    public var uri: String
    public var artworkPath: String?
    public var tracks: Int?

    public init(name: String, uri: String, artworkPath: String? = nil, tracks: Int? = nil) {
        self.name = name
        self.uri = uri
        self.artworkPath = artworkPath
        self.tracks = tracks
    }

    public var id: String { uri }
}

public struct SpotifyStatus: Sendable, Equatable, Codable {
    /// A client ID is set in `[spotify]`.
    public var configured: Bool
    public var signedIn: Bool
    /// Waiting for the browser sign-in to come back.
    public var signingIn: Bool
    public var user: String?
    public var playlists: [PlaylistRef]
    public var error: String?

    public init(configured: Bool = false, signedIn: Bool = false, signingIn: Bool = false,
                user: String? = nil, playlists: [PlaylistRef] = [], error: String? = nil) {
        self.configured = configured
        self.signedIn = signedIn
        self.signingIn = signingIn
        self.user = user
        self.playlists = playlists
        self.error = error
    }
}

public struct LyricLine: Sendable, Equatable, Codable {
    /// Seconds into the track; nil for unsynced lyrics.
    public var time: Double?
    public var text: String

    public init(time: Double?, text: String) {
        self.time = time
        self.text = text
    }
}

/// Lyrics for one track (`MediaTrack.key`).
public struct Lyrics: Sendable, Equatable, Codable {
    public var key: String
    public var lines: [LyricLine]
    public var instrumental: Bool

    public init(key: String, lines: [LyricLine], instrumental: Bool = false) {
        self.key = key
        self.lines = lines
        self.instrumental = instrumental
    }

    public var isSynced: Bool { lines.first?.time != nil }

    /// The line sung at `position` seconds: the last one that has started.
    public func index(at position: Double) -> Int? {
        guard isSynced else { return nil }
        return lines.lastIndex { ($0.time ?? 0) <= position + 0.15 }
    }

    /// LRC text (`[mm:ss.xx] line`, several stamps allowed per line).
    /// Metadata tags like `[ar:...]` are skipped.
    public static func parseLRC(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for t in times { out.append(LyricLine(time: t, text: line)) }
        }
        return out.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    /// Plain lyrics, one line each (blank lines kept as breaks).
    public static func parsePlain(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines).map { LyricLine(time: nil, text: $0.trimmingCharacters(in: .whitespaces)) }
    }
}
