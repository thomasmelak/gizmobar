import Foundation
import GizmoCore

/// Loads every plugin in `~/.config/gizmobar/plugins`, feeds them provider
/// values from the bus, re-renders the ones whose inputs changed (at most
/// once per frame, and no faster than each `every`), and hands the trees to
/// the UI. Plugins with an `index.ts` newer than their bundle are rebuilt
/// with esbuild when it's installed; saving a file hot-reloads the plugin
/// and keeps its storage.
@MainActor
public final class PluginManager {
    public struct Info: Sendable {
        public var id: String
        public var name: String
        public var stats: RenderStats
        public var error: String?
        public var providers: [String]
    }

    private let bus: EventBus
    private var snapshot = BarSnapshot()
    private var plugins: [String: Loaded] = [:]
    private var dirty = Set<String>()
    private var flush: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var theme: [String: String] = [:]
    private var settings: [String: JSONValue] = [:]
    /// Publishes a plugin's tree (nil removes it).
    public var onTree: ((String, PluginNode?) -> Void)?
    public var onRequest: ((String) -> Void)?
    public var onOpen: ((URL) -> Void)?
    public var onLog: ((String, String, String) -> Void)?
    public private(set) var providerRates: [String: Int] = [:]

    private final class Loaded {
        let runtime: PluginRuntime
        var stats = RenderStats()
        var error: String?
        var uses: [String: Double] = [:]
        var lastFed: [String: Date] = [:]
        var topics = Set<String>()
        var renderQueued = false
        init(runtime: PluginRuntime) { self.runtime = runtime }
    }

    public init(bus: EventBus) {
        self.bus = bus
    }

    // MARK: Loading

    public func start(theme: Theme, settings: [String: JSONValue]) {
        self.theme = Self.tokens(theme)
        self.settings = settings
        listener = Task { [weak self, bus] in
            for await event in await bus.subscribe() {
                self?.received(event)
            }
        }
        Task { await reloadAll() }
    }

    public func update(theme: Theme, settings: [String: JSONValue]) {
        self.theme = Self.tokens(theme)
        self.settings = settings
        Task { await reloadAll() }
    }

    public func reloadAll() async {
        for (id, p) in plugins {
            await p.runtime.unload()
            onTree?(id, nil)
        }
        plugins = [:]
        for dir in Self.pluginDirs() {
            await load(dir)
        }
    }

    public var infos: [Info] {
        plugins.map { id, p in
            Info(id: id, name: p.runtime.manifest.name ?? id, stats: p.stats, error: p.error, providers: p.uses.keys.sorted())
        }.sorted { $0.id < $1.id }
    }

    public var ids: [String] { plugins.keys.sorted() }

    static func pluginDirs() -> [URL] {
        let root = GizmoPaths.pluginsDir
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("plugin.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func load(_ dir: URL) async {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            onLog?(dir.lastPathComponent, "error", "invalid plugin.json")
            return
        }
        let id = manifest.id
        if let problem = await PluginBuilder.buildIfNeeded(dir: dir, manifest: manifest) {
            onLog?(id, "error", problem)
        }
        let hooks = PluginRuntime.Hooks(
            log: { [weak self] level, msg in Task { @MainActor in self?.onLog?(id, level, msg) } },
            use: { [weak self] name, every in Task { @MainActor in self?.use(id, name, every) } },
            subscribe: { [weak self] topic in Task { @MainActor in self?.plugins[id]?.topics.insert(topic) } },
            emit: { [weak self] topic, payload in
                Task { @MainActor in await self?.bus.publish(topic: "plugin.\(id).\(topic)", payload: payload) }
            },
            request: { [weak self] name in Task { @MainActor in self?.onRequest?(name) } },
            open: { [weak self] url in Task { @MainActor in self?.onOpen?(url) } },
            rerender: { [weak self] in Task { @MainActor in self?.markDirty(id) } }
        )
        let runtime = PluginRuntime(directory: dir, manifest: manifest, hooks: hooks)
        let loaded = Loaded(runtime: runtime)
        plugins[id] = loaded
        let config = settings[id] ?? .object([:])
        if let error = await runtime.load(config: config, theme: theme) {
            loaded.error = error
            onTree?(id, .error(error))
            return
        }
        // Feed what it asked for, then draw.
        for name in loaded.uses.keys {
            if let v = PluginProviders.value(name, from: snapshot) { await runtime.setProvider(name, v) }
        }
        markDirty(id)
    }

    private func use(_ id: String, _ provider: String, _ every: Double) {
        guard let p = plugins[id] else { return }
        let first = p.uses[provider] == nil
        p.uses[provider] = max(p.uses[provider] ?? 0, every)
        if first, let v = PluginProviders.value(provider, from: snapshot) {
            Task { await p.runtime.setProvider(provider, v); markDirty(id) }
        }
    }

    // MARK: Events

    private func received(_ event: BarEvent) {
        snapshot.apply(event)
        let names = PluginProviders.providers(for: event.topic)
        for name in names { providerRates[name, default: 0] += 1 }
        let now = Date()
        for (id, p) in plugins where p.error == nil && !p.stats.paused {
            if p.topics.contains(event.topic) {
                let r = p.runtime, payload = event.payload, topic = event.topic
                Task { await r.dispatch(topic: topic, payload: payload); markDirty(id) }
            }
            for name in names {
                guard let every = p.uses[name] else { continue }
                if every > 0, let last = p.lastFed[name], now.timeIntervalSince(last) < every { continue }
                p.lastFed[name] = now
                guard let v = PluginProviders.value(name, from: snapshot) else { continue }
                let r = p.runtime
                Task { await r.setProvider(name, v); markDirty(id) }
            }
        }
    }

    private func markDirty(_ id: String) {
        dirty.insert(id)
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            await self?.renderDirty()
        }
    }

    private func renderDirty() async {
        let ids = dirty
        dirty = []
        flush = nil
        for id in ids {
            guard let p = plugins[id], p.error == nil, !p.stats.paused else { continue }
            let (node, ms) = await p.runtime.render()
            p.stats.record(ms)
            if p.stats.paused {
                onLog?(id, "warn", "paused: renders keep taking over 2 ms (last \(String(format: "%.1f", ms)) ms)")
                onTree?(id, .error("paused: over the 2 ms render budget"))
            } else {
                onTree?(id, node)
            }
        }
    }

    // MARK: From the UI

    public func invoke(_ id: String, _ callback: Int, _ arg: JSONValue = .null) {
        guard let p = plugins[id] else { return }
        Task {
            await p.runtime.invoke(callback, arg)
            markDirty(id)
        }
    }

    public func popover(_ id: String, _ callback: Int) async -> PluginNode {
        guard let p = plugins[id] else { return .error("no plugin \(id)") }
        return await p.runtime.renderPopover(callback)
    }

    /// Un-pauses a plugin that went over budget (on reload or by hand).
    public func resume(_ id: String) {
        plugins[id]?.stats.paused = false
        plugins[id]?.stats.overrunStreak = 0
        markDirty(id)
    }

    static func tokens(_ t: Theme) -> [String: String] {
        [
            "accent": t.accent, "icon": t.icon, "label": t.label, "good": t.good, "warn": t.warn, "bad": t.bad,
            "netUp": t.netUp, "netDown": t.netDown, "itemBackground": t.itemBackground, "itemBorder": t.itemBorder,
            "popupBackground": t.popupBackground,
        ]
    }
}

/// Bundles `index.ts` into the manifest's entry with esbuild when the
/// source is newer than the bundle.
public enum PluginBuilder {
    public static func esbuild() -> String? {
        let candidates = ["/opt/homebrew/bin/esbuild", "/usr/local/bin/esbuild"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/esbuild" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns a problem to report, or nil.
    public static func buildIfNeeded(dir: URL, manifest: PluginManifest) async -> String? {
        let fm = FileManager.default
        let source = ["index.ts", "index.tsx", "src/index.ts"].map { dir.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        let out = dir.appendingPathComponent(manifest.entry)
        guard let source else { return nil }
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        if let built = mtime(out), let src = mtime(source), built >= src { return nil }
        guard let esbuild = esbuild() else {
            return fm.fileExists(atPath: out.path) ? nil : "install esbuild (brew install esbuild) or run npm run build in \(dir.path)"
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: esbuild)
                p.arguments = args(source: source.path, out: out.path)
                let err = Pipe()
                p.standardError = err
                p.standardOutput = FileHandle.nullDevice
                do { try p.run() } catch { return cont.resume(returning: "esbuild: \(error)") }
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? nil : "esbuild failed:\n\(msg)")
            }
        }
    }

    /// The bundle format the runtime loads.
    public static func args(source: String, out: String) -> [String] {
        [source, "--bundle", "--format=iife", "--global-name=__plugin", "--platform=neutral",
         "--target=es2020", "--external:@gizmobar/sdk", "--log-level=error", "--outfile=\(out)"]
    }
}
