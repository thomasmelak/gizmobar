import AppKit
import ServiceManagement
import GizmoCore
import GizmoIPC
import GizmoProviders
import GizmoUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bus = EventBus()
    private var store: BarStore!
    private var panels: PanelManager!
    private var server: IPCServer?
    private var aerospace: AeroSpaceProvider!
    private var network: NetworkProvider!
    private var battery: BatteryProvider!
    private var audio: AudioProvider!
    private var displays: DisplaysProvider!
    private var providers: [any Provider] = []
    private var watcher: ConfigWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundCursor.enable()
        let config = loadConfig()
        store = BarStore(config: config, theme: Theme.load(named: config.theme), icons: makeResolver(config))
        store.attach(to: bus)

        aerospace = AeroSpaceProvider(settings: config.aerospace)
        network = NetworkProvider()
        battery = BatteryProvider()
        audio = AudioProvider()
        displays = DisplaysProvider()
        providers = [ClockProvider(), AppsProvider(), aerospace, SystemProvider(), network, battery, audio, displays]
        store.onRequest = { [weak self] name in self?.handleRequest(name) }
        store.onFocusWorkspace = { [aerospace] ws in
            Task { await aerospace?.focus(workspace: ws) }
        }
        let bus = self.bus
        for provider in providers {
            Task { await provider.start(bus: bus) }
        }

        panels = PanelManager(store: store)
        panels.start()
        startServer()
        updateLoginItem(config.launchAtLogin)

        watcher = ConfigWatcher(root: GizmoPaths.configDir) { [weak self] changes in
            guard let self else { return }
            if changes.contains(.config) || changes.contains(.theme) { self.reload() }
            else if changes.contains(.iconPacks) { self.reloadIcons() }
        }
        watcher?.start()
    }

    /// Requests from widgets, routed to the provider that owns them.
    private func handleRequest(_ name: String) {
        let (action, arg) = name.split(separator: ":", maxSplits: 1).map(String.init).splitFirst()
        let network = self.network!, battery = self.battery!, audio = self.audio!, displays = self.displays!
        Task {
            switch action {
            case BarRequest.refreshConnectivity: await network.refreshConnectivity()
            case BarRequest.toggleWiFi: await network.toggleWiFi()
            case BarRequest.toggleBluetooth: await network.toggleBluetooth()
            case BarRequest.batteryDetailsOn: await battery.setDetailed(true)
            case BarRequest.batteryDetailsOff: await battery.setDetailed(false)
            case BarRequest.toggleLowPower: await battery.toggleLowPower()
            case BarRequest.toggleNoSleep: await battery.toggleNoSleep()
            case BarRequest.setChargeLimit: await battery.setChargeLimit()
            case BarRequest.toggleMute: await audio.toggleMute()
            case "audio.volume": if let v = arg.flatMap(Double.init) { await audio.setVolume(v) }
            case "audio.output": if let id = arg.flatMap(UInt32.init) { await audio.select(id) }
            case BarRequest.refreshDisplays: await displays.refresh()
            case BarRequest.toggleNightShift: await displays.toggleNightShift()
            case "displays.brightness":
                if let a = Self.displayArg(arg) { await displays.setBrightness(display: a.0, a.1) }
            case "displays.contrast":
                if let a = Self.displayArg(arg) { await displays.setContrast(display: a.0, a.1) }
            case "displays.warmth": if let v = arg.flatMap(Int.init) { await displays.setWarmth(v) }
            default: NSLog("gizmobar: unknown request \(name)")
            }
        }
    }

    /// "<display id>,<value>"
    private nonisolated static func displayArg(_ arg: String?) -> (UInt32, Int)? {
        let parts = arg?.split(separator: ",") ?? []
        guard parts.count == 2, let id = UInt32(parts[0]), let v = Int(parts[1]) else { return nil }
        return (id, v)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        watcher?.stop()
    }

    // MARK: - Config

    private func loadConfig() -> GizmoConfig {
        do { return try GizmoConfig.load() } catch {
            NSLog("gizmobar: config error, using defaults: \(error)")
            return GizmoConfig()
        }
    }

    private func makeResolver(_ config: GizmoConfig) -> IconResolver {
        var dirs = [GizmoPaths.iconPacksDir]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("icon-packs") { dirs.insert(bundled, at: 0) }
        return IconResolver(settings: config.icons, packs: IconPack.loadAll(from: dirs))
    }

    /// Re-reads icon packs only; called when an SVG or pack file changes.
    private func reloadIcons() {
        store.invalidateIcons(makeResolver(store.config))
    }

    private func reload() {
        let config = loadConfig()
        let layoutChanged = config.bar != store.config.bar || config.layout != store.config.layout
        store.config = config
        store.theme = Theme.load(named: config.theme)
        store.invalidateIcons(makeResolver(config))
        if layoutChanged { panels.rebuild() }
        Task { await bus.publish(topic: Topic.configReloaded) }
    }

    private func updateLoginItem(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("gizmobar: login item: \(error)")
        }
    }

    // MARK: - CLI

    private func startServer() {
        let server = IPCServer { [weak self] req in
            await self?.handle(req) ?? .error("shutting down")
        }
        do { try server.start() } catch { NSLog("gizmobar: IPC server failed: \(error)") }
        self.server = server
    }

    private func handle(_ req: IPCRequest) async -> IPCResponse {
        switch req.command {
        case "ping":
            return .init(ok: true, message: "pong")
        case "trigger":
            guard let topic = req.args.first else { return .error("usage: gizmo trigger <topic> [k=v ...]") }
            await bus.publish(topic: topic, payload: req.payload)
            if topic.hasPrefix("aerospace.") { await aerospace.refresh(after: .zero) }
            return .init(ok: true)
        case "reload":
            reload()
            return .init(ok: true, message: "reloaded")
        case "state":
            let s = store.snapshot
            return .init(ok: true, data: [
                "focusedWorkspace": s.focusedWorkspace.map(JSONValue.string) ?? .null,
                "workspaces": .array(s.workspaces.map { .string($0.id) }),
                "frontApp": s.frontApp.map { .string($0.name) } ?? .null,
                "panels": .number(Double(panels.panelCount)),
                "subscribers": .number(Double(await bus.subscriberCount)),
            ])
        case "icons":
            return iconsCommand(req.args)
        default:
            return .error("unknown command: \(req.command)")
        }
    }

    private func iconsCommand(_ args: [String]) -> IPCResponse {
        switch args.first {
        case "missing":
            // Apps currently open whose icon came from the fallback.
            // TODO(phase 2): rank by usage over time, not just what's open now.
            var seen = Set<String>()
            var missing: [JSONValue] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let id = app.bundleIdentifier ?? ""
                guard seen.insert(id).inserted else { continue }
                if store.icons.resolve(bundleID: app.bundleIdentifier, appName: app.localizedName ?? "").isFallback {
                    missing.append(["bundleId": .string(id), "name": .string(app.localizedName ?? "")])
                }
            }
            return .init(ok: true, data: .array(missing))
        default:
            return .error("usage: gizmo icons missing")
        }
    }
}

private extension Array where Element == String {
    func splitFirst() -> (String, String?) {
        (first ?? "", count > 1 ? self[1] : nil)
    }
}
