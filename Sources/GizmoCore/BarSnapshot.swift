import Foundation

public struct WindowInfo: Sendable, Equatable, Hashable {
    public var id: Int
    public var workspace: String
    public var bundleID: String?
    public var appName: String

    public init(id: Int, workspace: String, bundleID: String?, appName: String) {
        self.id = id
        self.workspace = workspace
        self.bundleID = bundleID
        self.appName = appName
    }
}

public struct WorkspaceInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var isFocused: Bool
    /// One entry per distinct app on the workspace, in window order.
    public var apps: [AppRef]
    /// AeroSpace's monitor for it, as a 1-based index into `NSScreen.screens`
    /// (`%{monitor-appkit-nsscreen-screens-id}`); nil when unknown.
    public var monitor: Int?
    /// Shown on its monitor right now (each monitor shows one workspace).
    public var isVisible: Bool

    public init(id: String, isFocused: Bool = false, apps: [AppRef] = [], monitor: Int? = nil, isVisible: Bool = false) {
        self.id = id
        self.isFocused = isFocused
        self.apps = apps
        self.monitor = monitor
        self.isVisible = isVisible || isFocused
    }
}

public struct AppRef: Sendable, Equatable, Hashable {
    public var bundleID: String?
    public var name: String

    public init(bundleID: String?, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Everything the built-in widgets draw, as a pure value. The UI wraps it in
/// an observable store; keeping the reducer here makes it testable without AppKit.
public struct BarSnapshot: Sendable, Equatable {
    public var workspaces: [WorkspaceInfo] = []
    public var focusedWorkspace: String?
    public var windows: [WindowInfo] = []
    public var frontApp: AppRef?
    public var now: Date = .now
    public var system: SystemStats?
    public var cpuHistory = History()
    public var gpuHistory = History()
    public var temperatureHistory = History()
    public var swapHistory = History()
    public var network: NetworkSpeed = .offline
    public var connectivity: Connectivity?
    public var battery: BatteryStatus?
    public var audio: AudioStatus?
    public var displays: DisplaysStatus?
    public var nowPlaying = NowPlayingStatus()
    public var spotify = SpotifyStatus()
    /// Lyrics of the shown track, when found.
    public var lyrics: Lyrics?
    /// Apps making sound now or recently.
    public var audioSources: [AudioSource] = []
    /// Last payload per external `gizmo trigger` topic.
    public var triggers: [String: JSONValue] = [:]

    public init() {}

    public mutating func apply(_ event: BarEvent) {
        switch event.topic {
        case Topic.aerospaceSnapshot:
            windows = (event.payload["windows"]?.array ?? []).compactMap(Self.window(from:))
            if let f = event.payload["focused"]?.string { focusedWorkspace = f }
            workspaces = (event.payload["workspaces"]?.array ?? []).compactMap(Self.workspace(from:))
            rebuildWorkspaces()

        case Topic.aerospaceFocusedWorkspace, Topic.aerospaceFocus:
            if let ws = event.payload["workspace"]?.string, ws != focusedWorkspace {
                focus(ws)
            }

        case Topic.appsFront:
            if let name = event.payload["name"]?.string {
                frontApp = AppRef(bundleID: event.payload["bundleId"]?.string, name: name)
            }

        case Topic.systemStats:
            if let s = event.payload.decode(SystemStats.self) {
                system = s
                cpuHistory.push(s.cpu)
                if let g = s.gpu { gpuHistory.push(g) }
                if let t = s.temperatureFraction { temperatureHistory.push(t) }
                swapHistory.push(s.swapFraction)
            }

        case Topic.networkSpeed:
            if let n = event.payload.decode(NetworkSpeed.self) { network = n }

        case Topic.networkConnectivity:
            if let c = event.payload.decode(Connectivity.self) { connectivity = c }

        case Topic.battery:
            battery = event.payload.decode(BatteryStatus.self)

        case Topic.audio:
            audio = event.payload.decode(AudioStatus.self)

        case Topic.displays:
            displays = event.payload.decode(DisplaysStatus.self)

        case Topic.media:
            nowPlaying = event.payload.decode(NowPlayingStatus.self) ?? NowPlayingStatus()

        case Topic.spotify:
            spotify = event.payload.decode(SpotifyStatus.self) ?? SpotifyStatus()

        case Topic.lyrics:
            lyrics = event.payload.decode(Lyrics.self)

        case Topic.audioSources:
            audioSources = event.payload.decode(AudioSourcesStatus.self)?.sources ?? []

        case Topic.clockTick:
            if let t = event.payload["epoch"], case .number(let s) = t { now = Date(timeIntervalSince1970: s) }

        default:
            if !event.topic.hasPrefix("aerospace.") { triggers[event.topic] = event.payload }
        }
    }

    /// The workspaces the bar shows, applying `hide_empty`. With a `monitor`
    /// (the bar's display, 1-based like AeroSpace's appkit monitor id) and
    /// `per_monitor`, only that monitor's workspaces; the one it shows stays
    /// even when empty.
    public func visibleWorkspaces(_ settings: AeroSpaceSettings, monitor: Int? = nil) -> [WorkspaceInfo] {
        let monitor = settings.perMonitor ? monitor : nil
        return workspaces.filter { ws in
            if let monitor, let m = ws.monitor, m != monitor { return false }
            guard settings.hideEmpty else { return true }
            let current = ws.isFocused || (monitor != nil && ws.isVisible)
            return !ws.apps.isEmpty || (settings.showFocusedWhenEmpty && current)
        }
    }

    /// A focus change: the new workspace is now the one its monitor shows.
    private mutating func focus(_ id: String) {
        focusedWorkspace = id
        if let m = workspaces.first(where: { $0.id == id })?.monitor {
            for i in workspaces.indices where workspaces[i].monitor == m {
                workspaces[i].isVisible = workspaces[i].id == id
            }
        }
        rebuildWorkspaces()
    }

    private mutating func rebuildWorkspaces() {
        var byWorkspace: [String: [AppRef]] = [:]
        for w in windows {
            let ref = AppRef(bundleID: w.bundleID, name: w.appName)
            if byWorkspace[w.workspace, default: []].contains(ref) == false {
                byWorkspace[w.workspace, default: []].append(ref)
            }
        }
        workspaces = workspaces.map {
            var ws = $0
            ws.isFocused = ws.id == focusedWorkspace
            if ws.isFocused { ws.isVisible = true }
            ws.apps = byWorkspace[ws.id] ?? []
            return ws
        }
    }

    /// A bare workspace name, or a `list-workspaces --json --format` object
    /// with `workspace`, `monitor-appkit-nsscreen-screens-id` and
    /// `workspace-is-visible`.
    static func workspace(from v: JSONValue) -> WorkspaceInfo? {
        if let id = v.string { return WorkspaceInfo(id: id) }
        guard let id = v["workspace"]?.string else { return nil }
        let visible: Bool = {
            switch v["workspace-is-visible"] {
            case .bool(let b)?: return b
            case .string(let s)?: return s == "true"
            default: return false
            }
        }()
        return WorkspaceInfo(id: id, monitor: v["monitor-appkit-nsscreen-screens-id"]?.int, isVisible: visible)
    }

    /// Accepts AeroSpace's `list-windows --json` keys.
    static func window(from v: JSONValue) -> WindowInfo? {
        guard let id = v["window-id"]?.int, let ws = v["workspace"]?.string else { return nil }
        return WindowInfo(id: id, workspace: ws, bundleID: v["app-bundle-id"]?.string, appName: v["app-name"]?.string ?? "")
    }
}
