import Foundation
import TOMLDecoder

/// Design tokens, ported from the SketchyBar `themes/*.sh` files. Colors are
/// `#RRGGBB` or `#RRGGBBAA` strings so themes stay plain TOML.
public struct Theme: Sendable, Equatable, Decodable {
    public var name: String
    public var itemBackground: String
    public var itemBorder: String
    public var icon: String
    public var label: String
    public var workspaceBackground: String
    public var workspaceIcon: String
    public var workspaceFocusBackground: String
    public var workspaceFocusBorder: String
    public var workspaceFocusIcon: String
    public var accent: String
    public var popupBackground: String
    public var popupBorder: String
    public var good: String
    public var warn: String
    public var bad: String
    public var cornerRadius: Double
    public var font: String
    public var fontSize: Double

    enum CodingKeys: String, CodingKey {
        case name
        case itemBackground = "item_bg"
        case itemBorder = "item_border"
        case icon, label
        case workspaceBackground = "ws_bg"
        case workspaceIcon = "ws_icon"
        case workspaceFocusBackground = "ws_focus_bg"
        case workspaceFocusBorder = "ws_focus_border"
        case workspaceFocusIcon = "ws_focus_icon"
        case accent
        case popupBackground = "popup_bg"
        case popupBorder = "popup_border"
        case good, warn, bad
        case cornerRadius = "corner_radius"
        case font
        case fontSize = "font_size"
    }

    /// The default Gizmo theme (Tefer colors), built in so the bar works with no theme files.
    public static let gizmo = Theme(
        name: "Gizmo",
        itemBackground: "#0d053399", itemBorder: "#2a1a6e", icon: "#6e89ff", label: "#e6f4ff",
        workspaceBackground: "#0d053373", workspaceIcon: "#7a74b8",
        workspaceFocusBackground: "#1d0f5c99", workspaceFocusBorder: "#b77cff", workspaceFocusIcon: "#b77cff",
        accent: "#b77cff", popupBackground: "#0d0533b8", popupBorder: "#b77cff",
        good: "#5fd38d", warn: "#ffc857", bad: "#ff5c7a",
        cornerRadius: 10, font: "SF Pro Text", fontSize: 13
    )

    public init(
        name: String, itemBackground: String, itemBorder: String, icon: String, label: String,
        workspaceBackground: String, workspaceIcon: String, workspaceFocusBackground: String,
        workspaceFocusBorder: String, workspaceFocusIcon: String, accent: String,
        popupBackground: String, popupBorder: String, good: String, warn: String, bad: String,
        cornerRadius: Double, font: String, fontSize: Double
    ) {
        self.name = name; self.itemBackground = itemBackground; self.itemBorder = itemBorder
        self.icon = icon; self.label = label; self.workspaceBackground = workspaceBackground
        self.workspaceIcon = workspaceIcon; self.workspaceFocusBackground = workspaceFocusBackground
        self.workspaceFocusBorder = workspaceFocusBorder; self.workspaceFocusIcon = workspaceFocusIcon
        self.accent = accent; self.popupBackground = popupBackground; self.popupBorder = popupBorder
        self.good = good; self.warn = warn; self.bad = bad
        self.cornerRadius = cornerRadius; self.font = font; self.fontSize = fontSize
    }

    /// Missing keys fall back to the Gizmo theme, so a theme file only needs
    /// the colors it changes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = Theme.gizmo
        func s(_ k: CodingKeys, _ d: String) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? d }
        name = try s(.name, t.name)
        itemBackground = try s(.itemBackground, t.itemBackground)
        itemBorder = try s(.itemBorder, t.itemBorder)
        icon = try s(.icon, t.icon)
        label = try s(.label, t.label)
        workspaceBackground = try s(.workspaceBackground, t.workspaceBackground)
        workspaceIcon = try s(.workspaceIcon, t.workspaceIcon)
        workspaceFocusBackground = try s(.workspaceFocusBackground, t.workspaceFocusBackground)
        workspaceFocusBorder = try s(.workspaceFocusBorder, t.workspaceFocusBorder)
        workspaceFocusIcon = try s(.workspaceFocusIcon, t.workspaceFocusIcon)
        accent = try s(.accent, t.accent)
        popupBackground = try s(.popupBackground, t.popupBackground)
        popupBorder = try s(.popupBorder, t.popupBorder)
        good = try s(.good, t.good)
        warn = try s(.warn, t.warn)
        bad = try s(.bad, t.bad)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? t.cornerRadius
        font = try s(.font, t.font)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? t.fontSize
    }

    public static func load(named name: String, in dir: URL = GizmoPaths.themesDir) -> Theme {
        let url = dir.appendingPathComponent("\(name).toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let theme = try? TOMLDecoder().decode(Theme.self, from: text)
        else { return .gizmo }
        return theme
    }
}

/// Parses `#RGB`, `#RRGGBB`, `#RRGGBBAA` and SketchyBar's `0xAARRGGBB`.
public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        var sketchybar = false
        if s.hasPrefix("#") { s.removeFirst() }
        else if s.lowercased().hasPrefix("0x") { s.removeFirst(2); sketchybar = true }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        func byte(_ shift: UInt64) -> Double { Double((v >> shift) & 0xff) / 255 }
        if s.count == 6 {
            self.init(r: byte(16), g: byte(8), b: byte(0))
        } else if sketchybar {
            self.init(r: byte(16), g: byte(8), b: byte(0), a: byte(24))
        } else {
            self.init(r: byte(24), g: byte(16), b: byte(8), a: byte(0))
        }
    }
}
