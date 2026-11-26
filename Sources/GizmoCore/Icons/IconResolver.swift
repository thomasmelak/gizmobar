import Foundation

/// What to draw for an app. GizmoUI turns this into a cached image.
public enum IconChoice: Sendable, Equatable {
    /// The app's real macOS icon; `mono` tones it down to one color.
    case system(bundleID: String, mono: Bool)
    /// A single-color SVG, tinted with `tint` (nil = theme foreground).
    case svg(URL, tint: String?)
    /// A ligature in an icon font such as sketchybar-app-font.
    case glyph(String, font: String, tint: String?)
    /// A letter in a rounded square in the app's color.
    case monogram(Character, color: String?)
    /// A neutral app glyph.
    case generic
}

public struct ResolvedIcon: Sendable, Equatable {
    public let choice: IconChoice
    /// Where the choice came from: "override", "system-style", a pack id, or "fallback".
    public let source: String
    public var isFallback: Bool { source == "fallback" }
}

/// Picks an app's icon in the plan's order:
/// per-app override → (style = system ⇒ system icon) → custom pack → other packs → fallback.
/// Matching is by bundle ID; pack `aliases.json` maps names for helpers and web apps.
public struct IconResolver: Sendable {
    public var settings: IconSettings
    public var packs: [String: IconPack]

    public init(settings: IconSettings, packs: [String: IconPack]) {
        self.settings = settings
        self.packs = packs
    }

    public func resolve(bundleID rawID: String?, appName: String) -> ResolvedIcon {
        let bundleID = rawID ?? alias(for: appName) ?? ""
        let brand = brandColor(for: bundleID)

        if let o = settings.apps[bundleID] {
            if let file = o.file {
                return .init(choice: .svg(GizmoPaths.expand(file), tint: o.color ?? tint(brand)), source: "override")
            }
            if let glyph = o.glyph, let pack = glyphPack(named: o.pack) {
                return .init(choice: .glyph(glyphString(glyph, pack: pack), font: pack.manifest.font ?? "", tint: o.color ?? tint(brand)), source: "override")
            }
            if o.style == .system, !bundleID.isEmpty {
                return .init(choice: .system(bundleID: bundleID, mono: false), source: "override")
            }
        }

        if settings.style == .system, !bundleID.isEmpty {
            return .init(choice: .system(bundleID: bundleID, mono: false), source: "system-style")
        }

        for id in settings.packOrder {
            guard let pack = packs[id], !bundleID.isEmpty else { continue }
            if let url = pack.svgURL(for: bundleID) {
                return .init(choice: .svg(url, tint: tint(brand)), source: pack.id)
            }
            if pack.manifest.kind == .font, let g = pack.glyphs[bundleID] {
                return .init(choice: .glyph(g, font: pack.manifest.font ?? "", tint: tint(brand)), source: pack.id)
            }
        }

        switch settings.fallback {
        case .system where !bundleID.isEmpty:
            return .init(choice: .system(bundleID: bundleID, mono: settings.systemLook == .mono), source: "fallback")
        case .monogram, .system:
            let letter = appName.first(where: { $0.isLetter || $0.isNumber }) ?? "?"
            return .init(choice: .monogram(letter.uppercased().first ?? letter, color: brand), source: "fallback")
        case .generic:
            return .init(choice: .generic, source: "fallback")
        }
    }

    /// Brand color from the first pack (in configured order) that knows the app.
    public func brandColor(for bundleID: String) -> String? {
        for id in settings.packOrder {
            if let c = packs[id]?.colors[bundleID] { return c }
        }
        return nil
    }

    private func tint(_ brand: String?) -> String? {
        switch settings.tint {
        case .brand: return brand
        case .theme, .none: return nil
        }
    }

    private func alias(for appName: String) -> String? {
        for id in settings.packOrder {
            if let b = packs[id]?.aliases[appName] { return b }
        }
        return nil
    }

    private func glyphPack(named name: String?) -> IconPack? {
        if let name { return packs[name] }
        return settings.packOrder.lazy.compactMap { packs[$0] }.first { $0.manifest.kind == .font }
    }

    private func glyphString(_ glyph: String, pack: IconPack) -> String {
        glyph.hasPrefix(":") ? glyph : ":\(glyph):"
    }
}
