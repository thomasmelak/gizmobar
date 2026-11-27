import Foundation
import Testing
@testable import GizmoCore
@testable import GizmoPlugins

/// Runs real plugins in JavaScriptCore. Bundles are written by hand in the
/// IIFE shape esbuild produces (`var __plugin = ...`).
@Suite("PluginRuntime", .serialized)
struct PluginRuntimeTests {
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        var uses: [String] = []
        var emits: [String] = []
        var requests: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    }

    func make(_ js: String, permissions: [String] = ["provider:cpu"], log: Log = Log()) throws -> PluginRuntime {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gizmo-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try js.write(to: dir.appendingPathComponent("dist/index.js"), atomically: true, encoding: .utf8)
        setenv("GIZMOBAR_STATE_DIR", dir.appendingPathComponent("state").path, 1)
        let manifest = PluginManifest(id: "test", version: "0.1.0", entry: "dist/index.js", permissions: permissions)
        let hooks = PluginRuntime.Hooks(
            log: { level, msg in log.add("\(level): \(msg)") },
            use: { name, _ in log.lock.lock(); log.uses.append(name); log.lock.unlock() },
            subscribe: { _ in },
            emit: { topic, _ in log.lock.lock(); log.emits.append(topic); log.lock.unlock() },
            request: { name in log.lock.lock(); log.requests.append(name); log.lock.unlock() },
            open: { _ in },
            rerender: {}
        )
        return PluginRuntime(directory: dir, manifest: manifest, hooks: hooks)
    }

    let cpuPlugin = #"""
    var __plugin = (() => {
      const { definePlugin, ui, fmt } = require("@gizmobar/sdk");
      let clicks = 0;
      return { default: definePlugin({
        id: "test",
        setup(ctx) {
          const cpu = ctx.use("cpu");
          clicks = ctx.storage.get("clicks") ?? 0;
          return () => ui.row({
            icon: "cpu",
            label: cpu.value ? fmt.percent(cpu.value.usage) + " " + clicks : "--",
            color: "theme.accent",
            onClick: () => { clicks++; ctx.storage.set("clicks", clicks); },
            popover: () => ui.column([ui.text("hi " + ctx.config.name)]),
          });
        },
      }) };
    })();
    """#

    @Test func rendersWithProviderValues() async throws {
        let log = Log()
        let rt = try make(cpuPlugin, log: log)
        let err = await rt.load(config: ["name": "there"], theme: ["accent": "#b77cff"])
        #expect(err == nil, "\(log.lines)")
        #expect(log.uses == ["cpu"])
        var (node, ms) = await rt.render()
        #expect(ms < 50)
        guard case .pill(let child, _, let onClick?, let popover?) = node, case .row(let kids, _) = child else {
            Issue.record("unexpected \(node)"); return
        }
        #expect(kids.last == .text("--", color: nil, size: nil, marquee: false, mono: false))

        await rt.setProvider("cpu", ["usage": .number(0.42), "gpu": .null, "temperature": .null])
        await rt.invoke(onClick)
        (node, _) = await rt.render()
        guard case .pill(let child2, _, _, _) = node, case .row(let kids2, _) = child2 else { Issue.record("\(node)"); return }
        #expect(kids2.last == .text("42% 1", color: nil, size: nil, marquee: false, mono: false))

        let pop = await rt.renderPopover(popover)
        #expect(pop == .column([.text("hi there", color: nil, size: nil, marquee: false, mono: false)], gap: nil))
        await rt.unload()

        // Storage survives a reload.
        _ = await rt.load(config: ["name": "x"], theme: [:])
        await rt.setProvider("cpu", ["usage": .number(0.5), "gpu": .null, "temperature": .null])
        (node, _) = await rt.render()
        guard case .pill(let child3, _, _, _) = node, case .row(let kids3, _) = child3 else { Issue.record("\(node)"); return }
        #expect(kids3.last == .text("50% 1", color: nil, size: nil, marquee: false, mono: false))
    }

    @Test func permissionsAreEnforced() async throws {
        let log = Log()
        let rt = try make(cpuPlugin, permissions: [], log: log)
        let err = await rt.load(config: .object([:]), theme: [:])
        #expect(err?.contains("provider:cpu") == true)
    }

    @Test func requestsNeedPermission() async throws {
        let js = #"""
        var __plugin = { default: { setup(ctx) { ctx.request("theme.set:nord"); ctx.emit("hello", { a: 1 }); return () => ({ kind: "spacer" }); } } };
        """#
        let log = Log()
        let rt = try make(js, permissions: ["requests"], log: log)
        #expect(await rt.load(config: .object([:]), theme: [:]) == nil)
        #expect(log.requests == ["theme.set:nord"])
        #expect(log.emits == ["hello"])
    }

    @Test func errorsBecomeErrorNodes() async throws {
        let js = #"var __plugin = { default: { setup(ctx) { return () => { throw new Error("boom"); }; } } };"#
        let rt = try make(js)
        #expect(await rt.load(config: .object([:]), theme: [:]) == nil)
        let (node, _) = await rt.render()
        guard case .error(let msg) = node else { Issue.record("\(node)"); return }
        #expect(msg.contains("boom"))
    }

    @Test(.enabled(if: ExecutionLimit.available)) func runawayRenderIsStopped() async throws {
        let js = #"var __plugin = { default: { setup(ctx) { return () => { while (true) {} }; } } };"#
        let rt = try make(js)
        #expect(await rt.load(config: .object([:]), theme: [:]) == nil)
        let (node, ms) = await rt.render()
        #expect(ms < 2000)
        if case .error = node {} else { Issue.record("expected an error, got \(node)") }
    }

    @Test func builderArgs() {
        let a = PluginBuilder.args(source: "index.ts", out: "dist/index.js")
        #expect(a.contains("--global-name=__plugin"))
        #expect(a.contains("--external:@gizmobar/sdk"))
    }
}
