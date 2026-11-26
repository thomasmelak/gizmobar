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
    private var providers: [any Provider] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = loadConfig()
        store = BarStore(config: config, theme: Theme.load(named: config.theme), icons: makeResolver(config))
        store.attach(to: bus)

        aerospace = AeroSpaceProvider(settings: config.aerospace)
        providers = [ClockProvider(), AppsProvider(), aerospace]
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
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

    private func reload() {
        let config = loadConfig()
        store.config = config
        store.theme = Theme.load(named: config.theme)
        store.icons = makeResolver(config)
        panels.rebuild()
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
