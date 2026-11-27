#if canImport(AppKit)
import AppKit
import GizmoCore

/// Front app from NSWorkspace activation notifications (push, no polling).
public actor AppsProvider: Provider {
    public nonisolated let id = "apps"
    private var token: NSObjectProtocol?
    private var usageLog = AppUsage.load()
    private var lastSave = Date.distantPast

    public init() {}

    public func start(bus: EventBus) async {
        if let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication.map(Self.describe) }) {
            await bus.publish(topic: Topic.appsFront, payload: app)
            record(app)
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let payload = Self.describe(app)
            Task {
                await bus.publish(topic: Topic.appsFront, payload: payload)
                await self?.record(payload)
            }
        }
    }

    public func stop() async {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
        usageLog.credit()
        try? usageLog.save()
    }

    /// Usage so far, with the app in front credited up to now.
    public func usage() -> AppUsage {
        usageLog.credit()
        return usageLog
    }

    private func record(_ app: JSONValue) {
        guard case .object(let o) = app, case .string(let id)? = o["bundleId"] else { return }
        var name = id
        if case .string(let n)? = o["name"] { name = n }
        usageLog.activate(id, name: name)
        // At most once a minute; the bar keeps the rest in memory.
        if Date().timeIntervalSince(lastSave) > 60 {
            lastSave = Date()
            try? usageLog.save()
        }
    }

    nonisolated static func describe(_ app: NSRunningApplication) -> JSONValue {
        [
            "name": .string(app.localizedName ?? ""),
            "bundleId": app.bundleIdentifier.map(JSONValue.string) ?? .null,
            "pid": .number(Double(app.processIdentifier)),
        ]
    }
}
#endif
