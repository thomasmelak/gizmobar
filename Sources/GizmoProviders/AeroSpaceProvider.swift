import Foundation
import GizmoCore

/// Workspaces and windows from AeroSpace.
///
/// Holds one long-lived `aerospace subscribe` stream (AeroSpace 0.21+) and
/// forwards each JSON line as `aerospace.<event>`. The workspace list and
/// windows are fetched once at start and re-fetched (debounced) when window
/// events arrive. If `subscribe` isn't available it falls back to callback
/// mode: `exec-on-workspace-change` runs `gizmo trigger aerospace.workspace`,
/// and the app calls `refresh()`.
public actor AeroSpaceProvider: Provider {
    public nonisolated let id = "aerospace"

    private let settings: AeroSpaceSettings
    private var bus: EventBus?
    private var binary: String?
    private var process: Process?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var stopped = false
    public private(set) var usingSubscribe = false

    static let events = ["focused-workspace-changed", "focus-changed", "focused-monitor-changed", "window-detected"]

    public init(settings: AeroSpaceSettings) {
        self.settings = settings
    }

    public func start(bus: EventBus) async {
        guard settings.mode != .off else { return }
        self.bus = bus
        stopped = false
        binary = settings.binary.map { GizmoPaths.expand($0).path }
            ?? Command.which("aerospace", candidates: ["/opt/homebrew/bin", "/usr/local/bin"])
        guard binary != nil else {
            await bus.publish(topic: "gizmobar.warning", payload: ["message": "aerospace not found"])
            return
        }
        await snapshot()
        if settings.mode == .subscribe { startStream(attempt: 0) }
    }

    public func stop() async {
        stopped = true
        streamTask?.cancel()
        refreshTask?.cancel()
        process?.terminate()
        process = nil
    }

    /// Debounced re-fetch of the workspace list and windows.
    public func refresh(after delay: Duration = .milliseconds(120)) {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.snapshot()
        }
    }

    /// Focus a workspace (pill click). Runs the CLI once on a user action.
    /// TODO(phase 1): talk to AeroSpace's socket directly instead.
    public func focus(workspace: String) async {
        guard let binary else { return }
        _ = try? await Command.run(binary, ["workspace", workspace])
    }

    private func snapshot() async {
        guard let binary, let bus else { return }
        do {
            async let all = workspaces(binary)
            async let focused = Command.run(binary, ["list-workspaces", "--focused", "--json"])
            async let windows = Command.run(binary, [
                "list-windows", "--all", "--json",
                "--format", "%{window-id} %{workspace} %{app-bundle-id} %{app-name}",
            ])
            let ws = try await all
            let f = try JSONValue(parsing: try await focused).array?.first?["workspace"] ?? .null
            let wins = try JSONValue(parsing: try await windows)
            await bus.publish(topic: Topic.aerospaceSnapshot, payload: ["workspaces": .array(ws), "focused": f, "windows": wins])
        } catch {
            await bus.publish(topic: "gizmobar.warning", payload: ["message": .string("aerospace snapshot failed: \(error)")])
        }
    }

    /// Every workspace with its monitor and whether that monitor shows it.
    /// Falls back to bare names on AeroSpace versions without those fields.
    private func workspaces(_ binary: String) async throws -> [JSONValue] {
        let fields = "%{workspace} %{monitor-appkit-nsscreen-screens-id} %{workspace-is-visible}"
        if let out = try? await Command.run(binary, ["list-workspaces", "--all", "--json", "--format", fields]),
           let list = try? JSONValue(parsing: out).array {
            return list
        }
        return try JSONValue(parsing: try await Command.run(binary, ["list-workspaces", "--all", "--json"]))
            .array?.compactMap { $0["workspace"] } ?? []
    }

    private func startStream(attempt: Int) {
        guard let binary, !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["subscribe"] + Self.events
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        process = p
        let started = ContinuousClock.now
        streamTask = Task {
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    await self.handle(line: line)
                }
            } catch {}
            await self.streamEnded(startedAt: started, attempt: attempt)
        }
    }

    private func handle(line: String) async {
        guard let bus, let value = try? JSONValue(parsing: Data(line.utf8)),
              let name = value["_event"]?.string else { return }
        usingSubscribe = true
        await bus.publish(topic: "aerospace.\(name)", key: nil, payload: value)
        if name == "window-detected" || name == "focus-changed" || name == "focused-monitor-changed"
            || name == "focused-workspace-changed" {
            refresh()
        }
    }

    private func streamEnded(startedAt: ContinuousClock.Instant, attempt: Int) async {
        process = nil
        guard !stopped else { return }
        // Exiting immediately on the first try means `subscribe` isn't supported.
        if attempt == 0, !usingSubscribe, ContinuousClock.now - startedAt < .seconds(1) {
            await bus?.publish(topic: "gizmobar.warning", payload: [
                "message": "aerospace subscribe unavailable; using callback mode (gizmo trigger aerospace.workspace)",
            ])
            return
        }
        let backoff = min(30.0, pow(2.0, Double(attempt)))
        try? await Task.sleep(for: .seconds(backoff))
        startStream(attempt: attempt + 1)
    }
}
