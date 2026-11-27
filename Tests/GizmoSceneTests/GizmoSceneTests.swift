import Foundation
import Testing
import simd
@testable import GizmoScene
import GizmoCore

/// Builds a GLB in memory: one triangle, a material, and a 1 s clip that
/// moves the node from x=0 to x=2.
func triangleGLB() -> Data {
    var bin = Data()
    func f(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bin.append(contentsOf: $0) } }
    for p: [Float] in [[0, 0, 0], [1, 0, 0], [0, 1, 0]] { p.forEach(f) }      // 0..<36 positions
    u16(0); u16(1); u16(2); u16(0)                                           // 36..<44 indices (+pad)
    f(0); f(1)                                                               // 44..<52 times
    for p: [Float] in [[0, 0, 0], [2, 0, 0]] { p.forEach(f) }                // 52..<76 translations
    let json = """
    {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
     "nodes":[{"name":"Body","mesh":0,"translation":[0,0,0]}],
     "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
     "materials":[{"name":"Paint","pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1],"metallicFactor":0}}],
     "buffers":[{"byteLength":\(bin.count)}],
     "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6},
                    {"buffer":0,"byteOffset":44,"byteLength":8},{"buffer":0,"byteOffset":52,"byteLength":24}],
     "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
                  {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"},
                  {"bufferView":2,"componentType":5126,"count":2,"type":"SCALAR"},
                  {"bufferView":3,"componentType":5126,"count":2,"type":"VEC3"}],
     "animations":[{"name":"slide","samplers":[{"input":2,"output":3}],"channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    """
    var j = Data(json.utf8)
    while j.count % 4 != 0 { j.append(0x20) }
    while bin.count % 4 != 0 { bin.append(0) }
    var out = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    u32(0x46546C67); u32(2); u32(UInt32(12 + 8 + j.count + 8 + bin.count))
    u32(UInt32(j.count)); u32(0x4E4F534A); out.append(j)
    u32(UInt32(bin.count)); u32(0x004E4942); out.append(bin)
    return out
}

@Suite("GLTF")
struct GLTFTests {
    @Test func parsesGLB() throws {
        let doc = try GLTFDocument.parse(glb: triangleGLB())
        #expect(doc.roots == [0])
        #expect(doc.nodes[0].name == "Body")
        #expect(doc.meshes[0].primitives[0].positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(doc.meshes[0].primitives[0].indices == [0, 1, 2])
        #expect(doc.materials[0].baseColor == SIMD4(1, 0, 0, 1))
        #expect(doc.materials[0].metallic == 0)
        #expect(doc.triangleCount == 1)
        #expect(doc.animations.map(\.name) == ["slide"])
        #expect(doc.animations[0].duration == 1)
    }

    @Test func samplesAnimation() throws {
        let c = try GLTFDocument.parse(glb: triangleGLB()).animations[0].channels[0]
        #expect(GLTFSampler.sample(c, at: 0.5).x == 1)
        #expect(GLTFSampler.sample(c, at: -1).x == 0)
        #expect(GLTFSampler.sample(c, at: 5).x == 2)
        let q0 = simd_quatf(angle: 0, axis: [0, 1, 0]).vector, q1 = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]).vector
        let mid = simd_quatf(vector: GLTFSampler.blend(q0, q1, 0.5, rotation: true))
        #expect(abs(mid.angle - .pi / 4) < 1e-4)
    }

    /// The status-pet example model, as make_bot.py writes it.
    @Test func loadsExampleBot() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("examples/gizmobar/plugins/status-pet/models/gizmo-bot.glb")
        let doc = try GLTFDocument.load(url)
        #expect(Set(doc.animations.map(\.name)) == ["idle", "dance", "run", "sleep", "wave"])
        #expect(doc.nodes.compactMap(\.name).contains("Antenna"))
        #expect(doc.triangleCount == 9 * 12)
    }

    @Test func rejectsGarbage() {
        #expect(throws: GLTFDocument.LoadError.notGLB) { try GLTFDocument.parse(glb: Data("nope nope nope nope nope".utf8)) }
    }
}

@Suite("Globe")
struct GlobeTests {
    @Test func landDots() {
        let all = GlobeMath.landDots(step: 1)
        #expect(all.count > 300)
        #expect(GlobeMath.landDots(step: 2).count < all.count)
        // Somewhere in Africa is land; the middle of the Pacific isn't.
        #expect(all.contains { abs($0.x - 4) <= 2 && abs($0.y - 22) <= 4 })
        #expect(!all.contains { abs($0.x - 0) <= 2 && abs($0.y - -150) <= 2 })
    }

    @Test func projection() {
        let front = GlobeMath.project(lat: 0, lon: 30, centerLon: 30, tilt: 0)
        #expect(abs(front.x) < 1e-9 && abs(front.y) < 1e-9 && abs(front.z - 1) < 1e-9)
        #expect(GlobeMath.project(lat: 0, lon: 210, centerLon: 30, tilt: 0).z < 0)
        #expect(GlobeMath.project(lat: 90, lon: 0, centerLon: 0, tilt: 0).y > 0.99)
    }

    @Test func sun() {
        // June solstice, noon UTC: overhead near the Tropic of Cancer at lon ~0.
        let june = Date(timeIntervalSince1970: 1_782_043_200)  // 2026-06-21 12:00 UTC
        let s = GlobeMath.subsolarPoint(at: june)
        #expect(abs(s.lat - 23.44) < 0.5)
        #expect(abs(s.lon) < 3)
        #expect(GlobeMath.daylight(lat: 0, lon: 0, sun: s) == 1)
        #expect(GlobeMath.daylight(lat: 0, lon: 180, sun: s) == 0)
    }
}

@Suite("SceneOptions")
struct SceneOptionsTests {
    @Test func parsesShorthands() throws {
        let json = ##"{"model":"models/pet.glb","size":28,"animation":{"clip":"dance","loop":false,"blend":0.3},"camera":{"yaw":-20},"look":"pbr","popover":{"size":240,"orbit":true},"parts":{"Head":{"color":"#ff0000","visible":false}},"spin":"slow"}"##
        let o = SceneOptions.parse(try JSONValue(parsing: Data(json.utf8)))
        #expect(o.model == "models/pet.glb")
        #expect(o.clip == "dance" && o.loop == false && o.blend == 0.3)
        #expect(o.yaw == -20 && o.look == .pbr && o.size == 28 && o.spin == 6)
        #expect(o.popoverSize == 240 && o.orbit)
        #expect(o.parts["Head"] == PartOverride(visible: false, color: "#ff0000"))
        let g = SceneOptions.parse(["builtin": "globe", "animation": "idle", "markers": [["lat": 1, "lon": 2, "pulse": true]]])
        #expect(g.builtin == "globe" && g.clip == "idle" && g.markers == [GlobeMarker(lat: 1, lon: 2, pulse: true)])
        // A popover function (a callback id) isn't a popover size.
        #expect(SceneOptions.parse(["popover": ["$fn": 3]]).popoverSize == nil)
    }
}
