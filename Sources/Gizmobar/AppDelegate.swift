import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import GizmoCore
import GizmoIPC
import GizmoPlugins
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
    private var apps: AppsProvider!
    private var media: MediaProvider!
    private var spectrum: SpectrumProvider!
    private var spotify: SpotifyProvider!
    private var lyrics: LyricsProvider!
    private var providers: [any Provider] = []
    private var watcher: ConfigWatcher?
    private var plugins: PluginManager!
    private var pluginLog: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        CLILink.ensure()
        BackgroundCursor.enable()
        let config = loadConfig()
        store = BarStore(config: config, theme: Theme.load(named: config.theme), icons: makeResolver(config))
        store.attach(to: bus)
        store.themes = Theme.catalog()

        aerospace = AeroSpaceProvider(settings: config.aerospace)
        network = NetworkProvider()
        battery = BatteryProvider()
        audio = AudioProvider()
        displays = DisplaysProvider()
        apps = AppsProvider()
        media = MediaProvider(settings: config.media)
        spectrum = SpectrumProvider(settings: config.media)
        spotify = SpotifyProvider(settings: config.spotify, media: media)
        lyrics = LyricsProvider(settings: config.lyrics)
        providers = [ClockProvider(), apps, aerospace, SystemProvider(), network, battery, audio, displays, media, spectrum, spotify, lyrics]
        watchPlayback()
        store.onRequest = { [weak self] name in self?.handleRequest(name) }
        store.onFocusWorkspace = { [aerospace] ws in
            Task { await aerospace?.focus(workspace: ws) }
        }
        let bus = self.bus
        for provider in providers {
            Task { await provider.start(bus: bus) }
        }

        startPlugins(config)
        panels = PanelManager(store: store)
        panels.start()
        // Plugging in or removing a display renumbers AeroSpace's monitors.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [aerospace] _ in
            Task { await aerospace?.refresh(after: .seconds(1)) }
        }
        startServer()
        updateLoginItem(config.launchAtLogin)

        watcher = ConfigWatcher(root: GizmoPaths.configDir) { [weak self] changes in
            guard let self else { return }
            if changes.contains(.config) || changes.contains(.theme) { self.reload() }
            else if changes.contains(.iconPacks) { self.reloadIcons() }
            if changes.contains(.plugins) { Task { await self.plugins.reloadAll() } }
        }
        watcher?.start()
    }

    // MARK: - Plugins

    private func startPlugins(_ config: GizmoConfig) {
        let manager = PluginManager(bus: bus)
        let store = self.store!
        manager.onTree = { id, node in
            if let node { store.plugins.trees[id] = node } else { store.plugins.trees[id] = nil }
        }
        manager.onRequest = { [weak self] name in self?.handleRequest(name) }
        manager.onOpen = { url in NSWorkspace.shared.open(url) }
        manager.onLog = { [weak self] id, level, msg in
            NSLog("gizmobar plugin \(id) [\(level)]: \(msg)")
            self?.pluginLog.append("\(id) [\(level)] \(msg)")
            if let n = self?.pluginLog.count, n > 200 { self?.pluginLog.removeFirst(n - 200) }
        }
        var sceneSeq = 0
        manager.onLoaded = { id, dir in store.plugins.directories[id] = dir }
        manager.onScene = { id, kind, payload in
            sceneSeq += 1
            store.plugins.sceneCommands[id] = SceneCommand(seq: sceneSeq, kind: kind, payload: payload)
        }
        store.plugins.invoke = { [weak manager] id, cb, arg in manager?.invoke(id, cb, arg) }
        store.plugins.dispatch = { [weak manager] id, topic, payload in manager?.dispatch(id, topic: topic, payload: payload) }
        store.plugins.popover = { [weak manager] id, cb in await manager?.popover(id, cb) ?? .error("gone") }
        manager.start(theme: store.theme, settings: config.plugins)
        plugins = manager
    }

    /// Requests from widgets, routed to the provider that owns them.
    private func handleRequest(_ name: String) {
        let (action, arg) = name.split(separator: ":", maxSplits: 1).map(String.init).splitFirst()
        switch action {
        case BarRequest.refreshThemes:
            store.themes = Theme.catalog()
            return
        case "theme.set":
            guard let id = arg else { return }
            saveConfig("theme", ConfigEditor.string(id))
            return
        case BarRequest.toggleIconStyle:
            let next: IconSettings.Style = store.config.icons.style == .custom ? .system : .custom
            saveConfig("style", ConfigEditor.string(next.rawValue), table: "icons")
            return
        case "icons.app.style":
            let parts = arg?.split(separator: ",").map(String.init) ?? []
            guard parts.count == 2 else { return }
            saveConfig(parts[0], "{ style = \(ConfigEditor.string(parts[1])) }", table: "icons.apps")
            return
        case "icons.app.file":
            if let id = arg { chooseIconFile(for: id) }
            return
        case "icons.app.reset":
            if let id = arg { saveConfig(id, nil, table: "icons.apps") }
            return
        case BarRequest.openIconPacks:
            try? FileManager.default.createDirectory(at: GizmoPaths.iconPacksDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(GizmoPaths.iconPacksDir)
            return
        default: break
        }
        let network = self.network!, battery = self.battery!, audio = self.audio!, displays = self.displays!, media = self.media!
        let spotify = self.spotify!
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
            case BarRequest.mediaToggle: await media.send(.toggle)
            case BarRequest.mediaNext: await media.send(.next)
            case BarRequest.mediaPrevious: await media.send(.previous)
            case BarRequest.mediaPreviousTrack: await media.send(.previousTrack)
            case BarRequest.mediaShuffle: await media.send(.shuffle)
            case BarRequest.mediaRepeat: await media.send(.repeat)
            case "media.seek": if let v = arg.flatMap(Double.init) { await media.seek(v) }
            case "media.select": if let id = arg { await media.select(id) }
            case BarRequest.spotifyLogin: await spotify.login()
            case BarRequest.spotifyLogout: await spotify.logout()
            case "spotify.play": if let uri = arg { await spotify.play(uri) }
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

    /// Listens to audio only while the bar shows now playing.
    private func watchPlayback() {
        let bus = self.bus, spectrum = self.spectrum!
        Task { @MainActor [weak self] in
            var wasShown: Bool?
            for await _ in await bus.subscribe(prefixes: [Topic.configReloaded]) {
                guard let self else { return }
                let shown = self.store.config.layout.all.contains("now_playing")
                if shown != wasShown {
                    wasShown = shown
                    await spectrum.setRunning(shown)
                }
            }
        }
        let shown = store.config.layout.all.contains("now_playing")
        Task { await spectrum.setRunning(shown) }
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

    /// Writes one setting to config.toml and reloads right away (the watcher
    /// would too, a moment later).
    private func saveConfig(_ key: String, _ value: String?, table: String? = nil) {
        do {
            try ConfigEditor.update(key, value, table: table)
            reload()
        } catch {
            NSLog("gizmobar: saving \(key): \(error)")
        }
    }

    /// "Choose File…" from an icon's menu: an SVG becomes that app's icon.
    private func chooseIconFile(for bundleID: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.directoryURL = GizmoPaths.iconPacksDir
        panel.message = "Choose a single-color SVG for this app"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        saveConfig(bundleID, "{ file = \(ConfigEditor.string(path)) }", table: "icons.apps")
    }

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
        let media = self.media!, spectrum = self.spectrum!, spotify = self.spotify!, lyrics = self.lyrics!
        Task {
            await media.update(settings: config.media)
            await spectrum.update(settings: config.media)
            await spotify.update(settings: config.spotify)
            await lyrics.update(settings: config.lyrics)
        }
        if layoutChanged { panels.rebuild() }
        plugins.update(theme: store.theme, settings: config.plugins)
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
                "nowPlaying": store.shownSource.map { .string($0.id) } ?? .null,
                "lyrics": s.lyrics.map { .object(["lines": .number(Double($0.lines.count)), "synced": .bool($0.isSynced)]) } ?? .null,
                "spotify": .object(["configured": .bool(s.spotify.configured), "signedIn": .bool(s.spotify.signedIn)]),
                "audioSources": .array(s.audioSources.map { a in
                    .object(["id": .string(a.id), "active": .bool(a.isActive), "spectrum": .bool(AudioFrameHub.shared.source(a.id) != nil)])
                }),
                "panels": .number(Double(panels.panelCount)),
                "subscribers": .number(Double(await bus.subscriberCount)),
            ])
        case "icons":
            return await iconsCommand(req.args)
        case "plugins":
            return await pluginsCommand(req.args)
        default:
            return .error("unknown command: \(req.command)")
        }
    }

    private func pluginsCommand(_ args: [String]) async -> IPCResponse {
        switch args.first {
        case "reload":
            await plugins.reloadAll()
            return .init(ok: true, message: "reloaded \(plugins.ids.count) plugin(s)")
        case "resume":
            guard args.count == 2 else { return .error("usage: gizmo plugins resume <id>") }
            plugins.resume(args[1])
            return .init(ok: true)
        case "log":
            return .init(ok: true, message: pluginLog.suffix(50).joined(separator: "\n"))
        default:
            // gizmo debug: per-plugin render times and provider update counts.
            let list: [JSONValue] = plugins.infos.map { i in
                [
                    "id": .string(i.id),
                    "renders": .number(Double(i.stats.renders)),
                    "avgMs": .number((i.stats.averageMs * 100).rounded() / 100),
                    "maxMs": .number((i.stats.maxMs * 100).rounded() / 100),
                    "overruns": .number(Double(i.stats.overruns)),
                    "paused": .bool(i.stats.paused),
                    "error": i.error.map(JSONValue.string) ?? .null,
                    "providers": .array(i.providers.map(JSONValue.string)),
                ]
            }
            let rates = plugins.providerRates.mapValues { JSONValue.number(Double($0)) }
            return .init(ok: true, data: ["plugins": .array(list), "providerUpdates": .object(rates)])
        }
    }

    private func iconsCommand(_ args: [String]) async -> IPCResponse {
        switch args.first {
        case "missing":
            // Apps you've used (most used first), then any open now that
            // haven't been seen yet, whose icon came from the fallback.
            let usage = await apps.usage()
            var rows: [(id: String, name: String, seconds: Double, activations: Int)] =
                usage.ranked.map { ($0.bundleID, $0.entry.name, $0.entry.seconds, $0.entry.activations) }
            var seen = Set(rows.map(\.id))
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
                rows.append((id, app.localizedName ?? id, 0, 0))
            }
            let missing: [JSONValue] = rows.compactMap { r in
                guard store.icons.resolve(bundleID: r.id, appName: r.name).isFallback else { return nil }
                return [
                    "bundleId": .string(r.id),
                    "name": .string(r.name),
                    "minutes": .number((r.seconds / 60).rounded()),
                    "activations": .number(Double(r.activations)),
                ]
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
