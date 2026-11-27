import Foundation

/// An app that plays sound, from its Core Audio process objects (helpers
/// such as a browser's audio process count as their app).
public struct AudioSource: Sendable, Equatable, Codable, Identifiable {
    /// The app's bundle ID.
    public var id: String
    public var name: String
    /// Producing sound right now.
    public var isActive: Bool
    /// When it was last heard (now, while active).
    public var lastHeard: Date

    public init(id: String, name: String, isActive: Bool, lastHeard: Date) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.lastHeard = lastHeard
    }
}

/// Which apps count as sound sources: media players, call apps and
/// browsers by default (not apps that only chime, like chat clients), plus
/// any app that reports now playing media, plus `[media] audio_sources`.
public enum AudioSourceFilter {
    public static let defaults: Set<String> = [
        // Players
        "com.spotify.client", "com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.QuickTimePlayerX",
        "com.colliderli.iina", "org.videolan.vlc", "com.tidal.desktop", "com.deezer.deezer-desktop", "com.amazon.music",
        "tv.plex.desktop", "com.soundcloud.desktop", "com.apple.iBooksX", "com.audible.mac",
        // Calls
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.hnc.Discord",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "com.skype.skype",
        // Browsers
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.apple.Safari",
        "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "app.zen-browser.zen", "org.chromium.Chromium",
    ]

    public static func allows(_ id: String, extra: [String], players: Set<String>) -> Bool {
        defaults.contains(id) || extra.contains(id) || players.contains(id)
    }
}

/// Apps playing now, then the ones heard recently, most recent first.
public struct AudioSourcesStatus: Sendable, Equatable, Codable {
    public var sources: [AudioSource]

    public init(sources: [AudioSource] = []) { self.sources = sources }

    /// Keeps active sources and those heard within `recent` seconds, active
    /// first, then most recently heard, at most `limit`.
    public static func ordered(_ all: [AudioSource], now: Date = Date(), recent: TimeInterval = 600, limit: Int = 8) -> [AudioSource] {
        all.filter { $0.isActive || now.timeIntervalSince($0.lastHeard) <= recent }
            .sorted { a, b in a.isActive != b.isActive ? a.isActive : a.lastHeard > b.lastHeard }
            .prefix(limit).map { $0 }
    }
}

/// What the now playing pill shows: a media player with its track and
/// controls, or any other app that makes sound (a call, a video, a game),
/// shown by name with its visualizer and no controls.
public enum ShownSource: Sendable, Equatable {
    case media(MediaSource)
    case audio(AudioSource)

    public var id: String {
        switch self {
        case .media(let m): m.id
        case .audio(let a): a.id
        }
    }

    public var name: String {
        switch self {
        case .media(let m): m.name
        case .audio(let a): a.name
        }
    }

    public var isPlaying: Bool {
        switch self {
        case .media(let m): m.isPlaying
        case .audio(let a): a.isActive
        }
    }

    /// `picked` is a source chosen in the popover. Otherwise: a playing
    /// media source, then any other app making sound, then a paused player.
    public static func choose(media: NowPlayingStatus, audio: [AudioSource], picked: String?) -> ShownSource? {
        let mediaIDs = Set(media.sources.map(\.id))
        let others = audio.filter { !mediaIDs.contains($0.id) }
        if let picked {
            if let m = media.sources.first(where: { $0.id == picked && $0.track != nil }) { return .media(m) }
            if let a = others.first(where: { $0.id == picked }) { return .audio(a) }
        }
        if let m = media.current, m.isPlaying { return .media(m) }
        if let a = others.first(where: \.isActive) { return .audio(a) }
        if let m = media.current { return .media(m) }
        return nil
    }
}
