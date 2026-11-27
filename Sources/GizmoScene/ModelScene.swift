#if canImport(RealityKit) && canImport(AppKit)
import AppKit
import RealityKit
import simd
import GizmoCore

/// A loaded model as a RealityKit entity tree, with its animation clips.
/// glTF/GLB goes through `GLTFDocument` (our reader); USDZ through RealityKit.
@MainActor
public final class ModelScene {
    public let root = Entity()
    public private(set) var clips: [String] = []
    /// Center and radius of the model, for framing.
    public private(set) var center: SIMD3<Float> = .zero
    public private(set) var radius: Float = 1

    private var gltf: GLTFDocument?
    private var nodes: [Int: Entity] = [:]
    private var rest: [Int: Transform] = [:]
    private var usdzAnimations: [String: AnimationResource] = [:]
    private var materials: [String: [ModelEntity]] = [:]

    /// Bar limits: bigger models load but cost more than a bar item should.
    public static let maxTriangles = 20_000

    public init() {}

    public static func load(_ url: URL, look: SceneDescriptor.Look) throws -> ModelScene {
        let scene = ModelScene()
        switch SceneModelFormat(path: url.path) {
        case .glb?, .gltf?:
            let doc = try GLTFDocument.load(url)
            if doc.triangleCount > maxTriangles {
                NSLog("gizmobar: \(url.lastPathComponent) has \(doc.triangleCount) triangles (bar limit \(maxTriangles))")
            }
            try scene.build(doc, look: look)
        case .usdz?:
            let entity = try Entity.load(contentsOf: url)
            scene.root.addChild(entity)
            for anim in entity.availableAnimations {
                let name = anim.name ?? "clip\(scene.usdzAnimations.count)"
                scene.usdzAnimations[name] = anim
            }
            scene.clips = scene.usdzAnimations.keys.sorted()
        case nil:
            throw GLTFDocument.LoadError.unsupported(url.pathExtension)
        }
        let b = scene.root.visualBounds(relativeTo: nil)
        scene.center = b.center
        scene.radius = max(simd_length(b.extents) / 2, 0.001)
        scene.root.generateCollisionShapes(recursive: true)
        return scene
    }

    // MARK: glTF

    private func build(_ doc: GLTFDocument, look: SceneDescriptor.Look) throws {
        gltf = doc
        clips = doc.animations.map(\.name)
        var textureCache: [Int: TextureResource] = [:]

        func texture(_ i: Int?) -> TextureResource? {
            guard let i, i < doc.textures.count, let img = doc.textures[i] else { return nil }
            if let t = textureCache[i] { return t }
            guard let src = CGImageSourceCreateWithData(img.data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                  ] as CFDictionary),
                  let t = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) else { return nil }
            textureCache[i] = t
            return t
        }

        func material(_ index: Int?) -> RealityKit.Material {
            let m = index.flatMap { $0 < doc.materials.count ? doc.materials[$0] : nil }
            let c = m?.baseColor ?? SIMD4(0.8, 0.8, 0.8, 1)
            let color = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
            let tex = texture(m?.baseColorTexture)
            switch look {
            case .pbr:
                var p = PhysicallyBasedMaterial()
                p.baseColor = .init(tint: color, texture: tex.map { .init($0) })
                p.metallic = .init(floatLiteral: m?.metallic ?? 0)
                p.roughness = .init(floatLiteral: m?.roughness ?? 0.6)
                if c.w < 1 { p.blending = .transparent(opacity: .init(floatLiteral: c.w)) }
                return p
            case .toon, .unlit:
                var u = UnlitMaterial(color: color)
                if let tex { u.color = .init(tint: color, texture: .init(tex)) }
                return u
            }
        }

        func make(_ i: Int) throws -> Entity {
            let n = doc.nodes[i]
            let e = Entity()
            e.name = n.name ?? "node\(i)"
            let t = Transform(scale: n.scale, rotation: n.rotation, translation: n.translation)
            e.transform = t
            nodes[i] = e
            rest[i] = t
            if let mi = n.mesh, mi < doc.meshes.count {
                for (pi, p) in doc.meshes[mi].primitives.enumerated() {
                    var d = MeshDescriptor(name: "\(e.name).\(pi)")
                    d.positions = MeshBuffers.Positions(p.positions)
                    if let normals = p.normals, normals.count == p.positions.count { d.normals = MeshBuffers.Normals(normals) }
                    if let uvs = p.uvs, uvs.count == p.positions.count {
                        // glTF's V runs down the image; RealityKit's runs up.
                        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs.map { SIMD2($0.x, 1 - $0.y) })
                    }
                    d.primitives = .triangles(p.indices)
                    let mesh = try MeshResource.generate(from: [d])
                    let model = ModelEntity(mesh: mesh, materials: [material(p.material)])
                    model.name = e.name
                    e.addChild(model)
                    materials[e.name, default: []].append(model)
                    if look == .toon, #available(macOS 15, *) {
                        // Outline: the same mesh a bit larger, dark, showing only its back faces.
                        // Back-face-only materials need macOS 15; macOS 14 gets no outline.
                        var outline = UnlitMaterial(color: NSColor(white: 0.05, alpha: 1))
                        outline.faceCulling = .front
                        let hull = ModelEntity(mesh: mesh, materials: [outline])
                        hull.scale = SIMD3(repeating: 1.04)
                        hull.name = e.name
                        e.addChild(hull)
                    }
                }
            }
            for c in n.children where c < doc.nodes.count { e.addChild(try make(c)) }
            return e
        }
        for r in doc.roots where r < doc.nodes.count { root.addChild(try make(r)) }
    }

    // MARK: Animation

    /// Sets the pose for `clip` at `time` (seconds), blended with `from`
    /// (another clip and its time) by `weight` (1 = only `clip`).
    public func pose(clip: String, time: Float, from: (clip: String, time: Float)? = nil, weight: Float = 1) {
        guard let doc = gltf else { return }
        func values(_ name: String, _ t: Float) -> [Int: [GLTFDocument.Path: SIMD4<Float>]] {
            guard let a = doc.animations.first(where: { $0.name == name }) else { return [:] }
            var out: [Int: [GLTFDocument.Path: SIMD4<Float>]] = [:]
            for c in a.channels { out[c.node, default: [:]][c.path] = GLTFSampler.sample(c, at: t) }
            return out
        }
        let target = values(clip, time)
        let previous = from.map { values($0.clip, $0.time) } ?? [:]
        for (i, e) in nodes {
            guard let base = rest[i] else { continue }
            func value(_ path: GLTFDocument.Path, _ restValue: SIMD4<Float>) -> SIMD4<Float> {
                let b = target[i]?[path] ?? restValue
                guard from != nil, weight < 1 else { return b }
                let a = previous[i]?[path] ?? restValue
                return GLTFSampler.blend(a, b, weight, rotation: path == .rotation)
            }
            let t = value(.translation, SIMD4(base.translation, 0))
            let r = value(.rotation, base.rotation.vector)
            let s = value(.scale, SIMD4(base.scale, 0))
            e.transform = Transform(scale: SIMD3(s.x, s.y, s.z), rotation: simd_quatf(vector: r), translation: SIMD3(t.x, t.y, t.z))
        }
    }

    public func duration(of clip: String) -> Float {
        gltf?.animations.first { $0.name == clip }?.duration ?? usdzAnimations[clip].map { Float($0.definition.duration) } ?? 0
    }

    /// USDZ clips play through RealityKit.
    public var usesRealityKitAnimation: Bool { gltf == nil }

    public func playUSDZ(_ clip: String, loop: Bool, blend: Double) {
        guard let anim = usdzAnimations[clip] else { return }
        for child in root.children {
            child.playAnimation(loop ? anim.repeat() : anim, transitionDuration: blend, startsPaused: false)
        }
    }

    // MARK: Parts

    public func apply(part name: String, _ o: PartOverride) {
        let entities = root.findEntity(named: name).map { [$0] } ?? []
        for e in entities {
            if let v = o.visible { e.isEnabled = v }
            if let r = o.rotation, r.count == 3 {
                let rad = r.map { Float($0) * .pi / 180 }
                e.orientation = simd_quatf(angle: rad[1], axis: [0, 1, 0]) * simd_quatf(angle: rad[0], axis: [1, 0, 0]) * simd_quatf(angle: rad[2], axis: [0, 0, 1])
            }
        }
        if let hex = o.color, let c = RGBA(hex: hex) {
            let color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
            for m in materials[name] ?? [] {
                m.model?.materials = m.model?.materials.map { mat -> RealityKit.Material in
                    if var u = mat as? UnlitMaterial { u.color = .init(tint: color, texture: u.color.texture); return u }
                    if var p = mat as? PhysicallyBasedMaterial { p.baseColor = .init(tint: color, texture: p.baseColor.texture); return p }
                    return mat
                } ?? []
            }
        }
    }

    /// The named part under a hit entity (walks up to a node name).
    public func partName(of entity: Entity) -> String? {
        var e: Entity? = entity
        while let cur = e, cur !== root {
            if !cur.name.isEmpty { return cur.name }
            e = cur.parent
        }
        return nil
    }
}
#endif
