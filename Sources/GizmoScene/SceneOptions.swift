import Foundation
import GizmoCore

/// `ui.scene({...})` / `ui.globe({...})` options as the UI uses them.
/// Accepts the shorthand forms from the docs: `animation: "idle"` or
/// `{ clip, loop, blend }`, `popover: { size, orbit }`.
public struct SceneOptions: Sendable, Equatable {
    public var model: String?
    public var builtin: String?
    public var clip: String?
    public var loop: Bool
    public var blend: Double
    public var look: SceneDescriptor.Look
    public var size: Double
    /// Degrees per second around the vertical axis.
    public var spin: Double
    public var yaw: Double
    public var popoverSize: Double?
    public var orbit: Bool
    public var parts: [String: PartOverride]
    public var markers: [GlobeMarker]
    public var caption: String?

    public static func parse(_ v: JSONValue) -> SceneOptions {
        func num(_ v: JSONValue?) -> Double? { if case .number(let n)? = v { return n }; return nil }
        func bool(_ v: JSONValue?) -> Bool? { if case .bool(let b)? = v { return b }; return nil }
        var o = SceneOptions(model: v["model"]?.string, builtin: v["builtin"]?.string, clip: nil, loop: true, blend: 0.25,
                             look: SceneDescriptor.Look(rawValue: v["look"]?.string ?? "") ?? .toon,
                             size: min(max(num(v["size"]) ?? 26, 12), 400), spin: 0, yaw: 0, popoverSize: nil, orbit: false,
                             parts: [:], markers: [], caption: v["caption"]?.string)
        if let s = v["animation"]?.string { o.clip = s }
        else if let a = v["animation"], case .object = a {
            o.clip = a["clip"]?.string
            o.loop = bool(a["loop"]) ?? true
            o.blend = num(a["blend"]) ?? 0.25
        }
        switch v["spin"] {
        case .number(let n)?: o.spin = n
        case .string(let s)?: o.spin = ["slow": 6, "medium": 15, "fast": 40][s] ?? 0
        case .bool(true)?: o.spin = 6
        default: break
        }
        o.yaw = num(v["camera"]?["yaw"]) ?? num(v["yaw"]) ?? 0
        if let p = v["popover"], case .object(let po) = p, po["$fn"] == nil {
            o.popoverSize = num(p["size"]) ?? 240
            o.orbit = bool(p["orbit"]) ?? true
        }
        if case .object(let parts)? = v["parts"] {
            for (name, p) in parts {
                o.parts[name] = PartOverride(visible: bool(p["visible"]), color: p["color"]?.string,
                                             rotation: p["rotation"]?.array?.compactMap { num($0) })
            }
        }
        o.markers = (v["markers"]?.array ?? []).compactMap { m in
            guard let lat = num(m["lat"]), let lon = num(m["lon"]) else { return nil }
            return GlobeMarker(lat: lat, lon: lon, color: m["color"]?.string, pulse: bool(m["pulse"]) ?? false, label: m["label"]?.string)
        }
        return o
    }
}
