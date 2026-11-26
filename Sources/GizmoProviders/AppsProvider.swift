#if canImport(AppKit)
import AppKit
import GizmoCore

/// Front app from NSWorkspace activation notifications (push, no polling).
public actor AppsProvider: Provider {
    public nonisolated let id = "apps"
    private var token: NSObjectProtocol?

    public init() {}

    public func start(bus: EventBus) async {
        if let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication.map(Self.describe) }) {
            await bus.publish(topic: Topic.appsFront, payload: app)
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let payload = Self.describe(app)
            Task { await bus.publish(topic: Topic.appsFront, payload: payload) }
        }
    }

    public func stop() async {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
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
