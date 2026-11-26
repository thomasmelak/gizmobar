import Foundation

/// An icon pack is a folder:
///
///     icon-packs/tefer-line/
///       pack.json      # id, name, kind, grid, stroke, license
///       colors.json    # brand color per bundle ID
///       aliases.json   # app-name / pattern → bundle ID
///       glyphs.json    # font packs only: bundle ID → ligature
///       icons/<bundle-id>.svg   # svg packs: single color, fill="currentColor"
public struct IconPack: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case svg
        /// A ligature font such as sketchybar-app-font.
        case font
    }

    public struct Manifest: Sendable, Equatable, Codable {
        public var id: String
        public var name: String
        public var kind: Kind
        public var grid: Double?
        public var stroke: Double?
        public var font: String?
        public var license: String?

        public init(id: String, name: String, kind: Kind, grid: Double? = nil, stroke: Double? = nil,
                    font: String? = nil, license: String? = nil)
        {
            self.id = id
            self.name = name
            self.kind = kind
            self.grid = grid
            self.stroke = stroke
            self.font = font
            self.license = license
        }
    }

    public let manifest: Manifest
    public let root: URL
    public let colors: [String: String]
    public let aliases: [String: String]
    public let glyphs: [String: String]
    public let svgBundleIDs: Set<String>

    public var id: String { manifest.id }

    public init(manifest: Manifest, root: URL, colors: [String: String] = [:], aliases: [String: String] = [:],
                glyphs: [String: String] = [:], svgBundleIDs: Set<String> = [])
    {
        self.manifest = manifest
        self.root = root
        self.colors = colors
        self.aliases = aliases
        self.glyphs = glyphs
        self.svgBundleIDs = svgBundleIDs
    }

    public static func load(from root: URL) throws -> IconPack {
        func json<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let manifestData = try Data(contentsOf: root.appendingPathComponent("pack.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let iconsDir = root.appendingPathComponent("icons", isDirectory: true)
        let svgs = (try? FileManager.default.contentsOfDirectory(atPath: iconsDir.path)) ?? []
        return IconPack(
            manifest: manifest,
            root: root,
            colors: json("colors.json", [String: String].self) ?? [:],
            aliases: json("aliases.json", [String: String].self) ?? [:],
            glyphs: json("glyphs.json", [String: String].self) ?? [:],
            svgBundleIDs: Set(svgs.filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) })
        )
    }

    /// Loads every pack folder under `dirs`, later folders winning on id clashes.
    public static func loadAll(from dirs: [URL]) -> [String: IconPack] {
        var packs: [String: IconPack] = [:]
        for dir in dirs {
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                if let pack = try? IconPack.load(from: entry) { packs[pack.id] = pack }
            }
        }
        return packs
    }

    func svgURL(for bundleID: String) -> URL? {
        guard manifest.kind == .svg, svgBundleIDs.contains(bundleID) else { return nil }
        return root.appendingPathComponent("icons/\(bundleID).svg")
    }
}
