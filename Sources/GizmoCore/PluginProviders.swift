import Foundation

/// What `ctx.use(name)` returns to a plugin, built from the bar's snapshot.
/// The field lists below are the single source of truth: `value(_:from:)`
/// emits exactly these keys and `typescript` generates the SDK's
/// `Providers` interface from them (`gizmo types`).
public enum PluginProviders {
    public struct Field: Sendable {
        public let name: String
        public let ts: String
        public init(_ name: String, _ ts: String) { self.name = name; self.ts = ts }
    }

    public struct Spec: Sendable {
        public let name: String
        public let doc: String
        /// Bus topics that change it.
        public let topics: [String]
        public let fields: [Field]
        /// The value is an array of `fields` objects instead of one object.
        public let isList: Bool
    }

    public static let specs: [Spec] = [
        Spec(name: "workspaces", doc: "AeroSpace workspaces.", topics: ["aerospace"], fields: [
            Field("focused", "string | null"),
            Field("list", "{ id: string; focused: boolean; apps: AppRef[] }[]"),
        ], isList: false),
        Spec(name: "apps", doc: "The frontmost app.", topics: [Topic.appsFront], fields: [
            Field("front", "AppRef | null"),
        ], isList: false),
        Spec(name: "clock", doc: "Ticks every second.", topics: [Topic.clockTick], fields: [
            Field("now", "number /* ms since 1970 */"),
        ], isList: false),
        Spec(name: "network", doc: "Throughput in bytes per second, and the connection.", topics: [Topic.networkSpeed, Topic.networkConnectivity], fields: [
            Field("up", "boolean"),
            Field("downBps", "number"),
            Field("upBps", "number"),
            Field("interface", "string | null"),
            Field("kind", "\"wifi\" | \"ethernet\" | \"none\""),
            Field("ip", "string | null"),
        ], isList: false),
        Spec(name: "cpu", doc: "Fractions 0...1; temperature in °C.", topics: [Topic.systemStats], fields: [
            Field("usage", "number"),
            Field("gpu", "number | null"),
            Field("temperature", "number | null"),
        ], isList: false),
        Spec(name: "memory", doc: "Bytes.", topics: [Topic.systemStats], fields: [
            Field("used", "number"),
            Field("total", "number"),
            Field("swapUsed", "number"),
            Field("swapTotal", "number"),
            Field("diskUsed", "number"),
            Field("diskTotal", "number"),
        ], isList: false),
        Spec(name: "power", doc: "The battery; percent is 0...100.", topics: [Topic.battery], fields: [
            Field("percent", "number"),
            Field("charging", "boolean"),
            Field("external", "boolean"),
            Field("lowPower", "boolean"),
            Field("minutesRemaining", "number | null"),
        ], isList: false),
        Spec(name: "media", doc: "The selected now playing source; position and duration in seconds.", topics: [Topic.media], fields: [
            Field("playing", "boolean"),
            Field("title", "string | null"),
            Field("artist", "string | null"),
            Field("album", "string | null"),
            Field("artwork", "string | null /* file path */"),
            Field("color", "Color | null /* picked from the art */"),
            Field("gradient", "Color[] | null /* a few distinct colors from the art */"),
            Field("position", "number"),
            Field("duration", "number"),
            Field("source", "string | null /* bundle ID */"),
        ], isList: false),
        Spec(name: "audio", doc: "Output volume 0...100.", topics: [Topic.audio], fields: [
            Field("volume", "number"),
            Field("muted", "boolean"),
            Field("output", "string | null"),
        ], isList: false),
        Spec(name: "displays", doc: "Brightness 0...100, null when unknown.", topics: [Topic.displays], fields: [
            Field("id", "number"),
            Field("name", "string"),
            Field("builtIn", "boolean"),
            Field("brightness", "number | null"),
        ], isList: true),
    ]

    public static var names: [String] { specs.map(\.name) }

    public static func spec(_ name: String) -> Spec? { specs.first { $0.name == name } }

    /// Providers a bus topic feeds.
    public static func providers(for topic: String) -> [String] {
        specs.filter { s in s.topics.contains { topic == $0 || topic.hasPrefix($0 + ".") } }.map(\.name)
    }

    public static func value(_ name: String, from s: BarSnapshot, at date: Date = Date()) -> JSONValue? {
        func app(_ a: AppRef?) -> JSONValue {
            guard let a else { return .null }
            return ["bundleId": a.bundleID.map(JSONValue.string) ?? .null, "name": .string(a.name)]
        }
        func opt<T>(_ v: T?, _ f: (T) -> JSONValue) -> JSONValue { v.map(f) ?? .null }
        func num(_ d: Double) -> JSONValue { .number(d) }
        switch name {
        case "workspaces":
            return [
                "focused": opt(s.focusedWorkspace, JSONValue.string),
                "list": .array(s.workspaces.map { ws in
                    ["id": .string(ws.id), "focused": .bool(ws.isFocused), "apps": .array(ws.apps.map { app($0) })]
                }),
            ]
        case "apps":
            return ["front": app(s.frontApp)]
        case "clock":
            return ["now": num((s.now.timeIntervalSince1970 * 1000).rounded())]
        case "network":
            let c = s.connectivity
            return [
                "up": .bool(s.network.interface != nil),
                "downBps": num(s.network.download),
                "upBps": num(s.network.upload),
                "interface": opt(s.network.interface, JSONValue.string),
                "kind": .string(c?.kind.rawValue ?? (s.network.interface == nil ? "none" : "ethernet")),
                "ip": opt(c?.ip, JSONValue.string),
            ]
        case "cpu":
            guard let st = s.system else { return nil }
            return ["usage": num(st.cpu), "gpu": opt(st.gpu, num), "temperature": opt(st.temperature, num)]
        case "memory":
            guard let st = s.system else { return nil }
            return [
                "used": num(Double(st.ramUsed)), "total": num(Double(st.ramTotal)),
                "swapUsed": num(Double(st.swapUsed)), "swapTotal": num(Double(st.swapTotal)),
                "diskUsed": num(Double(st.diskUsed)), "diskTotal": num(Double(st.diskTotal)),
            ]
        case "power":
            guard let b = s.battery else { return nil }
            return [
                "percent": num(Double(b.percent)), "charging": .bool(b.charging), "external": .bool(b.external),
                "lowPower": .bool(b.lowPower),
                "minutesRemaining": opt(b.charging ? b.minutesToFull : b.minutesToEmpty) { num(Double($0)) },
            ]
        case "media":
            let cur = s.nowPlaying.current
            let t = cur?.track
            return [
                "playing": .bool(cur?.isPlaying ?? false),
                "title": opt(t?.title, JSONValue.string),
                "artist": opt(t?.artist, JSONValue.string),
                "album": opt(t?.album, JSONValue.string),
                "artwork": opt(t?.artworkPath, JSONValue.string),
                "color": opt(t?.artColor, JSONValue.string),
                "gradient": opt(t?.artGradient) { .array($0.map(JSONValue.string)) },
                "position": num(cur?.position(at: date) ?? 0),
                "duration": num(t?.duration ?? 0),
                "source": opt(cur?.id, JSONValue.string),
            ]
        case "audio":
            guard let a = s.audio else { return nil }
            return [
                "volume": num(Double(a.volume)), "muted": .bool(a.muted),
                "output": opt(a.devices.first(where: \.isCurrent)?.name, JSONValue.string),
            ]
        case "displays":
            return .array((s.displays?.displays ?? []).map { d in
                ["id": num(Double(d.id)), "name": .string(d.name), "builtIn": .bool(d.isBuiltIn),
                 "brightness": opt(d.brightness) { num(Double($0)) }]
            })
        default:
            return nil
        }
    }

    /// sdk/src/providers.ts: `typescript` as a module of the SDK package.
    public static var typescriptModule: String {
        "import type { AppRef, Color } from \"./index.js\";\n\n" + typescript
    }

    /// The SDK's `Providers` interface, generated from `specs`.
    public static var typescript: String {
        var out = "// Generated by `gizmo types` from GizmoCore/PluginProviders.swift. Do not edit.\n"
        out += "export interface Providers {\n"
        for s in specs {
            out += "  /** \(s.doc) */\n"
            let body = s.fields.map { "    \($0.name): \($0.ts);" }.joined(separator: "\n")
            out += "  \(s.name): {\n\(body)\n  }\(s.isList ? "[]" : "");\n"
        }
        out += "}\n"
        return out
    }
}
