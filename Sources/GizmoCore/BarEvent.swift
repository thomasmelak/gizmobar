import Foundation

/// One message on the event bus. Topics are dotted names such as
/// `aerospace.focused-workspace-changed` or `apps.front`; external scripts add
/// their own through `gizmo trigger <topic> k=v`.
public struct BarEvent: Sendable, Hashable {
    public let topic: String
    /// Coalescing key: within one flush only the latest event per
    /// (topic, key) is delivered.
    public let key: String?
    public let payload: JSONValue
    public let at: ContinuousClock.Instant

    public init(topic: String, key: String? = nil, payload: JSONValue = .null, at: ContinuousClock.Instant = .now) {
        self.topic = topic
        self.key = key
        self.payload = payload
        self.at = at
    }

    public static func == (a: BarEvent, b: BarEvent) -> Bool {
        a.topic == b.topic && a.key == b.key && a.payload == b.payload && a.at == b.at
    }

    public func hash(into h: inout Hasher) {
        h.combine(topic); h.combine(key); h.combine(payload)
    }
}

/// Well-known topics published by the built-in providers.
public enum Topic {
    public static let aerospaceSnapshot = "aerospace.snapshot"
    public static let aerospaceFocusedWorkspace = "aerospace.focused-workspace-changed"
    public static let aerospaceFocus = "aerospace.focus-changed"
    public static let aerospaceMonitor = "aerospace.focused-monitor-changed"
    public static let aerospaceWindowDetected = "aerospace.window-detected"
    public static let appsFront = "apps.front"
    public static let clockTick = "clock.tick"
    public static let displaysChanged = "displays.changed"
    public static let configReloaded = "gizmobar.config-reloaded"
}
