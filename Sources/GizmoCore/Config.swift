import Foundation
import TOMLDecoder

/// `~/.config/gizmobar/config.toml`. Every key is optional; missing keys use
/// the defaults below so an empty file gives a working bar.
public struct GizmoConfig: Sendable, Equatable, Decodable {
    public var bar: BarSettings
    public var theme: String
    public var layout: Layout
    public var icons: IconSettings
    public var aerospace: AeroSpaceSettings
    public var logo: LogoSettings
    public var launchAtLogin: Bool

    public init(
        bar: BarSettings = .init(),
        theme: String = "gizmo",
        layout: Layout = .init(),
        icons: IconSettings = .init(),
        aerospace: AeroSpaceSettings = .init(),
        logo: LogoSettings = .init(),
        launchAtLogin: Bool = false
    ) {
        self.bar = bar
        self.theme = theme
        self.layout = layout
        self.icons = icons
        self.aerospace = aerospace
        self.logo = logo
        self.launchAtLogin = launchAtLogin
    }

    enum CodingKeys: String, CodingKey {
        case bar, theme, layout, icons, aerospace, logo
        case launchAtLogin = "launch_at_login"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GizmoConfig()
        bar = try c.decodeIfPresent(BarSettings.self, forKey: .bar) ?? d.bar
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? d.layout
        icons = try c.decodeIfPresent(IconSettings.self, forKey: .icons) ?? d.icons
        aerospace = try c.decodeIfPresent(AeroSpaceSettings.self, forKey: .aerospace) ?? d.aerospace
        logo = try c.decodeIfPresent(LogoSettings.self, forKey: .logo) ?? d.logo
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    public static func parse(_ toml: String) throws -> GizmoConfig {
        try TOMLDecoder().decode(GizmoConfig.self, from: toml)
    }

    /// Loads the config file, or returns defaults when it doesn't exist.
    public static func load(from url: URL = GizmoPaths.configFile) throws -> GizmoConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return GizmoConfig() }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }
}

public struct BarSettings: Sendable, Equatable, Decodable {
    public enum Edge: String, Sendable, Decodable { case top, bottom }
    public enum Displays: String, Sendable, Decodable { case all, main }

    public var position: Edge
    public var height: Double
    public var displays: Displays
    public var margin: Double
    public var glass: Bool

    public init(position: Edge = .bottom, height: Double = 40, displays: Displays = .all, margin: Double = 6, glass: Bool = true) {
        self.position = position
        self.height = height
        self.displays = displays
        self.margin = margin
        self.glass = glass
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BarSettings()
        position = try c.decodeIfPresent(Edge.self, forKey: .position) ?? d.position
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        displays = try c.decodeIfPresent(Displays.self, forKey: .displays) ?? d.displays
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? d.glass
    }

    enum CodingKeys: String, CodingKey { case position, height, displays, margin, glass }
}

/// Which widgets go where, by id. Built-ins: `workspaces`, `front_app`,
/// `clock`. Plugins (Phase 4) are referenced by their plugin id.
public struct Layout: Sendable, Equatable, Decodable {
    public var left: [String]
    public var center: [String]
    public var right: [String]

    public init(left: [String] = ["logo", "workspaces"], center: [String] = ["front_app"], right: [String] = ["clock"]) {
        self.left = left
        self.center = center
        self.right = right
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Layout()
        left = try c.decodeIfPresent([String].self, forKey: .left) ?? d.left
        center = try c.decodeIfPresent([String].self, forKey: .center) ?? d.center
        right = try c.decodeIfPresent([String].self, forKey: .right) ?? d.right
    }

    enum CodingKeys: String, CodingKey { case left, center, right }
}

public struct AeroSpaceSettings: Sendable, Equatable, Decodable {
    public enum Mode: String, Sendable, Decodable {
        /// One long-lived `aerospace subscribe` stream (AeroSpace 0.21+).
        case subscribe
        /// Older AeroSpace: `exec-on-workspace-change` runs `gizmo trigger`.
        case callback
        case off
    }

    public var mode: Mode
    public var binary: String?
    /// Old SketchyBar behaviour, now opt-in and never run mid-switch.
    public var moveWorkspaceToMonitor: Bool
    public var maxAppIcons: Int

    public init(mode: Mode = .subscribe, binary: String? = nil, moveWorkspaceToMonitor: Bool = false, maxAppIcons: Int = 8) {
        self.mode = mode
        self.binary = binary
        self.moveWorkspaceToMonitor = moveWorkspaceToMonitor
        self.maxAppIcons = maxAppIcons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AeroSpaceSettings()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        binary = try c.decodeIfPresent(String.self, forKey: .binary)
        moveWorkspaceToMonitor = try c.decodeIfPresent(Bool.self, forKey: .moveWorkspaceToMonitor) ?? d.moveWorkspaceToMonitor
        maxAppIcons = try c.decodeIfPresent(Int.self, forKey: .maxAppIcons) ?? d.maxAppIcons
    }

    enum CodingKeys: String, CodingKey {
        case mode, binary
        case moveWorkspaceToMonitor = "move_workspace_to_monitor"
        case maxAppIcons = "max_app_icons"
    }
}

/// `[logo]`: the mark at the start of the bar. With no `image` it shows the
/// Gizmobar app icon.
public struct LogoSettings: Sendable, Equatable, Decodable {
    /// Path to an SVG, PNG or PDF. Single-color SVGs can be tinted.
    public var image: String?
    /// Optional text after the image, e.g. "tefer".
    public var text: String?
    public var size: Double
    /// Tint for template images (`#RRGGBB`, or "accent"); nil keeps the colors.
    public var tint: String?
    /// Opened on click (any URL, e.g. a website or `x-apple.systempreferences:`).
    public var url: String?
    /// Run on click with /bin/sh when no `url` is set.
    public var command: String?

    public init(image: String? = nil, text: String? = nil, size: Double = 24, tint: String? = nil,
                url: String? = nil, command: String? = nil)
    {
        self.image = image
        self.text = text
        self.size = size
        self.tint = tint
        self.url = url
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 24
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        command = try c.decodeIfPresent(String.self, forKey: .command)
    }

    enum CodingKeys: String, CodingKey { case image, text, size, tint, url, command }
}
