import Foundation
import simd

/// A small glTF 2.0 reader (`.glb`, and `.gltf` with embedded or sibling
/// buffers): node hierarchy, triangle meshes with normals and UVs, base
/// color materials and textures, and node animations. Skins and morph
/// targets aren't read; such models load as their rest pose.
public struct GLTFDocument: Sendable {
    public struct Node: Sendable {
        public var name: String?
        public var children: [Int]
        public var mesh: Int?
        public var translation: SIMD3<Float>
        public var rotation: simd_quatf
        public var scale: SIMD3<Float>
    }

    public struct Primitive: Sendable {
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]?
        public var uvs: [SIMD2<Float>]?
        public var indices: [UInt32]
        public var material: Int?
    }

    public struct Mesh: Sendable {
        public var name: String?
        public var primitives: [Primitive]
    }

    public struct Material: Sendable {
        public var name: String?
        public var baseColor: SIMD4<Float>
        public var baseColorTexture: Int?
        public var metallic: Float
        public var roughness: Float
        public var emissive: SIMD3<Float>
    }

    public struct Image: Sendable {
        public var data: Data
        public var mimeType: String?
    }

    public enum Path: String, Sendable { case translation, rotation, scale }
    public enum Interpolation: String, Sendable { case linear = "LINEAR", step = "STEP", cubic = "CUBICSPLINE" }

    public struct Channel: Sendable {
        public var node: Int
        public var path: Path
        public var interpolation: Interpolation
        public var times: [Float]
        /// xyz for translation/scale, xyzw for rotation.
        public var values: [SIMD4<Float>]
    }

    public struct Animation: Sendable {
        public var name: String
        public var channels: [Channel]
        public var duration: Float { channels.compactMap(\.times.last).max() ?? 0 }
    }

    public var nodes: [Node] = []
    public var roots: [Int] = []
    public var meshes: [Mesh] = []
    public var materials: [Material] = []
    /// Texture index → image.
    public var textures: [Image?] = []
    public var animations: [Animation] = []

    public var triangleCount: Int {
        meshes.reduce(0) { $0 + $1.primitives.reduce(0) { $0 + $1.indices.count / 3 } }
    }

    public enum LoadError: Error, Equatable {
        case notGLB, badChunk, badJSON, missingBuffer(Int), badAccessor(Int), unsupported(String)
    }

    // MARK: Loading

    public static func load(_ url: URL) throws -> GLTFDocument {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "glb" { return try parse(glb: data) }
        return try parse(json: data, bin: nil, base: url.deletingLastPathComponent())
    }

    public static func parse(glb data: Data) throws -> GLTFDocument {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int {
            guard o + 4 <= bytes.count else { return 0 }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        guard bytes.count >= 20, u32(0) == 0x46546C67, u32(4) == 2 else { throw LoadError.notGLB }
        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= bytes.count {
            let length = u32(offset), type = u32(offset + 4)
            let start = offset + 8, end = start + length
            guard end <= bytes.count else { throw LoadError.badChunk }
            if type == 0x4E4F534A { json = Data(bytes[start..<end]) }
            else if type == 0x004E4942 { bin = Data(bytes[start..<end]) }
            offset = end
        }
        guard let json else { throw LoadError.badChunk }
        return try parse(json: json, bin: bin, base: nil)
    }

    static func parse(json: Data, bin: Data?, base: URL?) throws -> GLTFDocument {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw LoadError.badJSON }
        func arr(_ k: String) -> [[String: Any]] { root[k] as? [[String: Any]] ?? [] }

        // Buffers: the GLB chunk, data: URIs, or files next to the .gltf.
        var buffers: [Data] = []
        for (i, b) in arr("buffers").enumerated() {
            if let uri = b["uri"] as? String {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                    buffers.append(Data(base64Encoded: String(uri[uri.index(after: comma)...])) ?? Data())
                } else if let base, let d = try? Data(contentsOf: base.appendingPathComponent(uri.removingPercentEncoding ?? uri)) {
                    buffers.append(d)
                } else { throw LoadError.missingBuffer(i) }
            } else if let bin { buffers.append(bin) } else { throw LoadError.missingBuffer(i) }
        }
        let views = arr("bufferViews")
        let accessors = arr("accessors")

        func viewData(_ index: Int) -> (Data, Int)? {
            guard index < views.count else { return nil }
            let v = views[index]
            let b = v["buffer"] as? Int ?? 0
            guard b < buffers.count else { return nil }
            let off = v["byteOffset"] as? Int ?? 0, len = v["byteLength"] as? Int ?? 0
            let buf = buffers[b]
            guard off + len <= buf.count else { return nil }
            return (buf.subdata(in: off..<off + len), v["byteStride"] as? Int ?? 0)
        }

        /// Reads an accessor as floats, `components` per element.
        func floats(_ index: Int) throws -> (values: [Float], components: Int) {
            guard index < accessors.count else { throw LoadError.badAccessor(index) }
            let a = accessors[index]
            let count = a["count"] as? Int ?? 0
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][a["type"] as? String ?? ""] ?? 1
            let ctype = a["componentType"] as? Int ?? 5126
            let normalized = a["normalized"] as? Bool ?? false
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][ctype] ?? 4
            guard let bv = a["bufferView"] as? Int else { return ([Float](repeating: 0, count: count * comps), comps) }
            guard let (data, strideRaw) = viewData(bv) else { throw LoadError.badAccessor(index) }
            let start = a["byteOffset"] as? Int ?? 0
            let stride = strideRaw > 0 ? strideRaw : size * comps
            guard count == 0 || start + stride * (count - 1) + size * comps <= data.count else { throw LoadError.badAccessor(index) }
            var out = [Float](repeating: 0, count: count * comps)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    for c in 0..<comps {
                        let o = start + i * stride + c * size
                        let v: Float
                        switch ctype {
                        case 5126: v = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                        case 5125: v = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        case 5123:
                            let u = raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)
                            v = normalized ? Float(u) / 65535 : Float(u)
                        case 5122:
                            let s = raw.loadUnaligned(fromByteOffset: o, as: Int16.self)
                            v = normalized ? max(Float(s) / 32767, -1) : Float(s)
                        case 5121:
                            let u = raw.load(fromByteOffset: o, as: UInt8.self)
                            v = normalized ? Float(u) / 255 : Float(u)
                        default:
                            let s = raw.load(fromByteOffset: o, as: Int8.self)
                            v = normalized ? max(Float(s) / 127, -1) : Float(s)
                        }
                        out[i * comps + c] = v
                    }
                }
            }
            return (out, comps)
        }

        func vec3(_ f: [Float]) -> [SIMD3<Float>] { stride(from: 0, to: f.count - 2, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) } }
        func vec2(_ f: [Float]) -> [SIMD2<Float>] { stride(from: 0, to: f.count - 1, by: 2).map { SIMD2(f[$0], f[$0 + 1]) } }

        var doc = GLTFDocument()

        for n in arr("nodes") {
            var node = Node(name: n["name"] as? String, children: n["children"] as? [Int] ?? [], mesh: n["mesh"] as? Int,
                            translation: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), scale: .one)
            if let m = (n["matrix"] as? [NSNumber])?.map(\.floatValue), m.count == 16 {
                let mat = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                                  SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
                node.translation = SIMD3(mat.columns.3.x, mat.columns.3.y, mat.columns.3.z)
                let sx = simd_length(SIMD3(mat.columns.0.x, mat.columns.0.y, mat.columns.0.z))
                let sy = simd_length(SIMD3(mat.columns.1.x, mat.columns.1.y, mat.columns.1.z))
                let sz = simd_length(SIMD3(mat.columns.2.x, mat.columns.2.y, mat.columns.2.z))
                node.scale = SIMD3(sx, sy, sz)
                let r = simd_float3x3(SIMD3(mat.columns.0.x, mat.columns.0.y, mat.columns.0.z) / max(sx, 1e-6),
                                      SIMD3(mat.columns.1.x, mat.columns.1.y, mat.columns.1.z) / max(sy, 1e-6),
                                      SIMD3(mat.columns.2.x, mat.columns.2.y, mat.columns.2.z) / max(sz, 1e-6))
                node.rotation = simd_quatf(r)
            }
            if let t = (n["translation"] as? [NSNumber])?.map(\.floatValue), t.count == 3 { node.translation = SIMD3(t[0], t[1], t[2]) }
            if let r = (n["rotation"] as? [NSNumber])?.map(\.floatValue), r.count == 4 { node.rotation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]) }
            if let s = (n["scale"] as? [NSNumber])?.map(\.floatValue), s.count == 3 { node.scale = SIMD3(s[0], s[1], s[2]) }
            doc.nodes.append(node)
        }
        let sceneIndex = root["scene"] as? Int ?? 0
        let scenes = arr("scenes")
        if sceneIndex < scenes.count, let roots = scenes[sceneIndex]["nodes"] as? [Int] {
            doc.roots = roots
        } else {
            let children = Set(doc.nodes.flatMap(\.children))
            doc.roots = doc.nodes.indices.filter { !children.contains($0) }
        }

        for m in arr("meshes") {
            var mesh = Mesh(name: m["name"] as? String, primitives: [])
            for p in m["primitives"] as? [[String: Any]] ?? [] {
                let mode = p["mode"] as? Int ?? 4
                guard mode == 4, let attrs = p["attributes"] as? [String: Int], let pos = attrs["POSITION"] else { continue }
                let positions = vec3(try floats(pos).values)
                let normals = try attrs["NORMAL"].map { vec3(try floats($0).values) }
                let uvs = try attrs["TEXCOORD_0"].map { vec2(try floats($0).values) }
                let indices: [UInt32] = try (p["indices"] as? Int).map { try floats($0).values.map { UInt32($0) } }
                    ?? (0..<UInt32(positions.count)).map { $0 }
                mesh.primitives.append(Primitive(positions: positions, normals: normals, uvs: uvs, indices: indices, material: p["material"] as? Int))
            }
            doc.meshes.append(mesh)
        }

        for m in arr("materials") {
            let pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let bc = (pbr["baseColorFactor"] as? [NSNumber])?.map(\.floatValue) ?? [1, 1, 1, 1]
            let em = (m["emissiveFactor"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0]
            doc.materials.append(Material(
                name: m["name"] as? String,
                baseColor: bc.count == 4 ? SIMD4(bc[0], bc[1], bc[2], bc[3]) : .one,
                baseColorTexture: (pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int,
                metallic: (pbr["metallicFactor"] as? NSNumber)?.floatValue ?? 1,
                roughness: (pbr["roughnessFactor"] as? NSNumber)?.floatValue ?? 1,
                emissive: em.count == 3 ? SIMD3(em[0], em[1], em[2]) : .zero
            ))
        }

        let images: [Image?] = arr("images").map { img in
            if let bv = img["bufferView"] as? Int, let (d, _) = viewData(bv) { return Image(data: d, mimeType: img["mimeType"] as? String) }
            if let uri = img["uri"] as? String {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                    return Data(base64Encoded: String(uri[uri.index(after: comma)...])).map { Image(data: $0, mimeType: nil) }
                }
                if let base, let d = try? Data(contentsOf: base.appendingPathComponent(uri.removingPercentEncoding ?? uri)) {
                    return Image(data: d, mimeType: nil)
                }
            }
            return nil
        }
        doc.textures = arr("textures").map { t in (t["source"] as? Int).flatMap { $0 < images.count ? images[$0] : nil } }

        for (i, a) in arr("animations").enumerated() {
            let samplers = a["samplers"] as? [[String: Any]] ?? []
            var anim = Animation(name: a["name"] as? String ?? "clip\(i)", channels: [])
            for c in a["channels"] as? [[String: Any]] ?? [] {
                guard let si = c["sampler"] as? Int, si < samplers.count,
                      let target = c["target"] as? [String: Any], let node = target["node"] as? Int,
                      let path = Path(rawValue: target["path"] as? String ?? ""),
                      let input = samplers[si]["input"] as? Int, let output = samplers[si]["output"] as? Int else { continue }
                let interp = Interpolation(rawValue: samplers[si]["interpolation"] as? String ?? "LINEAR") ?? .linear
                let times = try floats(input).values
                let (raw, comps) = try floats(output)
                var values: [SIMD4<Float>] = stride(from: 0, to: raw.count - comps + 1, by: comps).map { o in
                    SIMD4(raw[o], comps > 1 ? raw[o + 1] : 0, comps > 2 ? raw[o + 2] : 0, comps > 3 ? raw[o + 3] : 0)
                }
                // Cubic spline keyframes are (in-tangent, value, out-tangent): keep the values.
                if interp == .cubic { values = stride(from: 1, to: values.count, by: 3).map { values[$0] } }
                guard values.count >= times.count, !times.isEmpty else { continue }
                anim.channels.append(Channel(node: node, path: path, interpolation: interp, times: times, values: Array(values.prefix(times.count))))
            }
            doc.animations.append(anim)
        }
        return doc
    }
}

/// Samples glTF animation channels.
public enum GLTFSampler {
    /// The channel's value at `time` (clamped to the clip).
    public static func sample(_ c: GLTFDocument.Channel, at time: Float) -> SIMD4<Float> {
        let t = c.times
        guard let first = t.first, let last = t.last else { return .zero }
        if time <= first { return c.values[0] }
        if time >= last { return c.values[t.count - 1] }
        // Binary search for the segment.
        var lo = 0, hi = t.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= time { lo = mid } else { hi = mid }
        }
        let a = c.values[lo], b = c.values[hi]
        if c.interpolation == .step { return a }
        let f = (time - t[lo]) / max(t[hi] - t[lo], 1e-6)
        if c.path == .rotation {
            let q = simd_slerp(simd_quatf(vector: a), simd_quatf(vector: b), f)
            return q.vector
        }
        return a + (b - a) * f
    }

    /// Blends two poses: `f` = 0 is `a`, 1 is `b`.
    public static func blend(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ f: Float, rotation: Bool) -> SIMD4<Float> {
        if rotation { return simd_slerp(simd_quatf(vector: a), simd_quatf(vector: b), f).vector }
        return a + (b - a) * f
    }
}
