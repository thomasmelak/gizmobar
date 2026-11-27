import Foundation

/// A plugin's widget tree, as the host draws it. Plugins build it with the
/// SDK's `ui.*` helpers; functions in it (onClick, onChange, popover) are
/// swapped for callback ids by the runtime before the tree crosses over.
public indirect enum PluginNode: Sendable, Equatable {
    case row([PluginNode], gap: Double?)
    case column([PluginNode], gap: Double?)
    case pill(PluginNode, focused: Bool, onClick: Int?, popover: Int?)
    case text(String, color: String?, size: Double?, marquee: Bool, mono: Bool)
    case icon(String, color: String?, size: Double?)
    case image(String, size: Double?, radius: Double?)
    case appIcon(String, style: String)
    case graph([Double], color: String?, width: Double?)
    case slider(Double, onChange: Int?)
    case toggle(Bool, onChange: Int?)
    case button(String, icon: String?, onClick: Int?)
    case scene(JSONValue, onClick: Int?, popover: Int?)
    case spacer
    /// A render that failed or a node the host doesn't know.
    case error(String)

    /// Parses the JSON the runtime hands over. Callbacks arrive as
    /// `{"$fn": <id>}`.
    public static func parse(_ v: JSONValue, depth: Int = 0) -> PluginNode {
        guard depth < 64 else { return .error("tree too deep") }
        guard case .object(let o) = v, let kind = o["kind"]?.string else {
            if v == .null { return .spacer }
            return .error("not a node")
        }
        func num(_ k: String) -> Double? { if case .number(let n)? = o[k] { return n }; return nil }
        func bool(_ k: String) -> Bool { if case .bool(let b)? = o[k] { return b }; return false }
        func fn(_ k: String) -> Int? {
            guard case .object(let f)? = o[k], case .number(let id)? = f["$fn"] else { return nil }
            return Int(id)
        }
        func children() -> [PluginNode] { (o["children"]?.array ?? []).prefix(256).map { parse($0, depth: depth + 1) } }
        switch kind {
        case "row": return .row(children(), gap: num("gap"))
        case "column", "stack": return .column(children(), gap: num("gap"))
        case "pill":
            return .pill(o["child"].map { parse($0, depth: depth + 1) } ?? .spacer,
                         focused: bool("focused"), onClick: fn("onClick"), popover: fn("popover"))
        case "text":
            return .text(o["text"]?.string ?? "", color: o["color"]?.string, size: num("size"), marquee: bool("marquee"), mono: bool("mono"))
        case "icon": return .icon(o["name"]?.string ?? "questionmark", color: o["color"]?.string, size: num("size"))
        case "image": return .image(o["src"]?.string ?? "", size: num("size"), radius: num("radius"))
        case "appIcon": return .appIcon(o["bundleId"]?.string ?? "", style: o["style"]?.string ?? "auto")
        case "graph":
            let values = (o["values"]?.array ?? []).suffix(512).compactMap { v -> Double? in
                if case .number(let n) = v { return n }
                return nil
            }
            return .graph(values, color: o["color"]?.string, width: num("width"))
        case "slider": return .slider(min(max(num("value") ?? 0, 0), 1), onChange: fn("onChange"))
        case "toggle": return .toggle(bool("value"), onChange: fn("onChange"))
        case "button": return .button(o["label"]?.string ?? "", icon: o["icon"]?.string, onClick: fn("onClick"))
        case "scene": return .scene(o["scene"] ?? .object([:]), onClick: fn("onClick"), popover: fn("popover"))
        case "spacer": return .spacer
        default: return .error("unknown node \(kind)")
        }
    }

    /// Resolves `"theme.accent"`-style colors against the theme tokens.
    public static func color(_ c: String?, theme: [String: String]) -> String? {
        guard let c else { return nil }
        if c.hasPrefix("theme.") { return theme[String(c.dropFirst(6))] }
        return c
    }
}

/// How long renders take, for the 2 ms budget and `gizmo debug`.
public struct RenderStats: Sendable, Equatable, Codable {
    public var renders = 0
    public var totalMs = 0.0
    public var maxMs = 0.0
    public var lastMs = 0.0
    /// Renders in a row over budget; reset by one under it.
    public var overrunStreak = 0
    public var overruns = 0
    public var paused = false

    public init() {}

    public var averageMs: Double { renders > 0 ? totalMs / Double(renders) : 0 }

    /// Records a render. Pauses after `limit` overruns in a row.
    public mutating func record(_ ms: Double, budget: Double = 2, limit: Int = 5) {
        renders += 1
        totalMs += ms
        maxMs = max(maxMs, ms)
        lastMs = ms
        if ms > budget {
            overruns += 1
            overrunStreak += 1
            if overrunStreak >= limit { paused = true }
        } else {
            overrunStreak = 0
        }
    }
}
