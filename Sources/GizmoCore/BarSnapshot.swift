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
    public var monitor: Int?

    public init(id: String, isFocused: Bool = false, apps: [AppRef] = [], monitor: Int? = nil) {
        self.id = id
        self.isFocused = isFocused
        self.apps = apps
        self.monitor = monitor
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
    /// Last payload per external `gizmo trigger` topic.
    public var triggers: [String: JSONValue] = [:]

    public init() {}

    public mutating func apply(_ event: BarEvent) {
        switch event.topic {
        case Topic.aerospaceSnapshot:
            let ids = event.payload["workspaces"]?.array?.compactMap(\.string) ?? []
            windows = (event.payload["windows"]?.array ?? []).compactMap(Self.window(from:))
            if let f = event.payload["focused"]?.string { focusedWorkspace = f }
            workspaces = ids.map { WorkspaceInfo(id: $0) }
            rebuildWorkspaces()

        case Topic.aerospaceFocusedWorkspace:
            if let ws = event.payload["workspace"]?.string {
                focusedWorkspace = ws
                rebuildWorkspaces()
            }

        case Topic.aerospaceFocus:
            if let ws = event.payload["workspace"]?.string, ws != focusedWorkspace {
                focusedWorkspace = ws
                rebuildWorkspaces()
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

        case Topic.clockTick:
            if let t = event.payload["epoch"], case .number(let s) = t { now = Date(timeIntervalSince1970: s) }

        default:
            if !event.topic.hasPrefix("aerospace.") { triggers[event.topic] = event.payload }
        }
    }

    /// The workspaces the bar shows, applying `hide_empty`.
    public func visibleWorkspaces(_ settings: AeroSpaceSettings) -> [WorkspaceInfo] {
        guard settings.hideEmpty else { return workspaces }
        return workspaces.filter { !$0.apps.isEmpty || (settings.showFocusedWhenEmpty && $0.isFocused) }
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
            ws.apps = byWorkspace[ws.id] ?? []
            return ws
        }
    }

    /// Accepts AeroSpace's `list-windows --json` keys.
    static func window(from v: JSONValue) -> WindowInfo? {
        guard let id = v["window-id"]?.int, let ws = v["workspace"]?.string else { return nil }
        return WindowInfo(id: id, workspace: ws, bundleID: v["app-bundle-id"]?.string, appName: v["app-name"]?.string ?? "")
    }
}
