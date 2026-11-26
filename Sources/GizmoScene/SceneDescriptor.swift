import Foundation
import GizmoCore

/// What a plugin asks for with `ui.scene({...})`. The engine (Phase 5) turns
/// this into a RealityKit entity, or a Metal render if RealityKit costs too
/// much at bar size.
public struct SceneDescriptor: Sendable, Equatable, Codable {
    public enum Look: String, Sendable, Codable {
        /// Toon shading with an outline, to match the line icons.
        case toon
        case pbr
        case unlit
    }

    public enum Source: Sendable, Equatable, Codable {
        /// A glTF/GLB or USDZ file, usually in the plugin's `models/` folder.
        case model(path: String)
        /// A scene that ships with the app, e.g. `globe`.
        case builtin(name: String)
    }

    public var source: Source
    /// Named animation clip to loop, if the model has clips.
    public var animation: String?
    public var look: Look
    /// Size on the bar in points (height; width follows the model's bounds).
    public var size: Double
    public var spin: Double?
    /// Per-part overrides, by node name.
    public var parts: [String: PartOverride]

    public init(source: Source, animation: String? = nil, look: Look = .toon, size: Double = 26, spin: Double? = nil,
                parts: [String: PartOverride] = [:])
    {
        self.source = source
        self.animation = animation
        self.look = look
        self.size = size
        self.spin = spin
        self.parts = parts
    }
}

public struct PartOverride: Sendable, Equatable, Codable {
    public var visible: Bool?
    public var color: String?
    public var rotation: [Double]?

    public init(visible: Bool? = nil, color: String? = nil, rotation: [Double]? = nil) {
        self.visible = visible
        self.color = color
        self.rotation = rotation
    }
}

public enum SceneModelFormat: String, Sendable {
    case gltf, glb, usdz

    public init?(path: String) {
        self.init(rawValue: (path as NSString).pathExtension.lowercased())
    }
}

/// The contract every renderer implements. Draws on demand: 0 fps when still,
/// up to 30 fps while a clip plays, nothing while the panel is occluded.
public protocol SceneRenderer: AnyObject {
    func load(_ descriptor: SceneDescriptor) async throws
    func play(clip: String, once: Bool)
    func set(part: String, _ override: PartOverride)
    var clips: [String] { get }
    var isOccluded: Bool { get set }
}
