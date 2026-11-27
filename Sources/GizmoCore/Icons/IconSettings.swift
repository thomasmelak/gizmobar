import Foundation

/// `[icons]` in config.toml.
public struct IconSettings: Sendable, Equatable, Decodable {
    public enum Style: String, Sendable, Decodable {
        /// Your custom pack first, then the other packs, then the fallback.
        case custom
        /// Skip the packs and show real macOS icons everywhere.
        case system
    }

    public enum Fallback: String, Sendable, Decodable { case system, monogram, generic }
    public enum Tint: String, Sendable, Decodable { case brand, theme, none }
    public enum SystemLook: String, Sendable, Decodable { case mono, color }

    public var style: Style
    /// Id of your custom pack, a folder in `~/.config/gizmobar/icon-packs/`
    /// (or bundled). Any pack can be the custom one; it's tried first and
    /// reloaded live as you add or edit icons.
    public var customPack: String?
    /// Further packs, tried in order after the custom pack.
    public var packs: [String]
    public var fallback: Fallback
    public var tint: Tint
    public var systemLook: SystemLook
    /// Marks fallback icons with a small dot on the bar.
    public var debugFallbacks: Bool
    /// Per-app overrides keyed by bundle ID.
    public var apps: [String: AppIconOverride]

    public init(
        style: Style = .custom,
        customPack: String? = "custom-icons",
        packs: [String] = ["tefer-line", "sketchybar-app-font"],
        fallback: Fallback = .system,
        tint: Tint = .brand,
        systemLook: SystemLook = .mono,
        debugFallbacks: Bool = false,
        apps: [String: AppIconOverride] = [:]
    ) {
        self.style = style
        self.customPack = customPack
        self.packs = packs
        self.fallback = fallback
        self.tint = tint
        self.systemLook = systemLook
        self.debugFallbacks = debugFallbacks
        self.apps = apps
    }

    enum CodingKeys: String, CodingKey {
        case style, packs, fallback, tint, apps
        case customPack = "custom_pack"
        case systemLook = "system_look"
        case debugFallbacks = "debug_fallbacks"
    }

    /// The custom pack followed by the other packs, without duplicates.
    public var packOrder: [String] {
        var seen = Set<String>()
        return ([customPack].compactMap { $0 } + packs).filter { seen.insert($0).inserted }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IconSettings()
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? d.style
        if c.contains(.customPack) {
            customPack = try c.decodeIfPresent(String.self, forKey: .customPack)
        } else {
            customPack = d.customPack
        }
        if customPack?.isEmpty == true { customPack = nil }
        packs = try c.decodeIfPresent([String].self, forKey: .packs) ?? d.packs
        fallback = try c.decodeIfPresent(Fallback.self, forKey: .fallback) ?? d.fallback
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? d.tint
        systemLook = try c.decodeIfPresent(SystemLook.self, forKey: .systemLook) ?? d.systemLook
        debugFallbacks = try c.decodeIfPresent(Bool.self, forKey: .debugFallbacks) ?? d.debugFallbacks
        apps = try c.decodeIfPresent([String: AppIconOverride].self, forKey: .apps) ?? d.apps
    }
}

/// One `[icons.apps]` entry. Exactly one of `style`, `file` or `glyph` is
/// expected; `color` optionally overrides the tint.
public struct AppIconOverride: Sendable, Equatable, Decodable {
    public var style: IconSettings.Style?
    public var file: String?
    public var glyph: String?
    public var pack: String?
    public var color: String?

    public init(style: IconSettings.Style? = nil, file: String? = nil, glyph: String? = nil, pack: String? = nil, color: String? = nil) {
        self.style = style
        self.file = file
        self.glyph = glyph
        self.pack = pack
        self.color = color
    }
}
