#if canImport(AppKit) && canImport(MetalKit)
import AppKit
import Metal
import MetalKit
import simd
import GizmoCore

/// Where a visualizer sits; sets the camera, depth and frame rate.
public enum VisualizerPlacement: Sendable, Equatable {
    /// Behind the track title in the bar pill.
    case bar
    /// The large one in the popover.
    case popup
    /// A small one in a list row.
    case row
}

/// What the view needs to know; set from SwiftUI.
public struct VisualizerConfig: Sendable, Equatable {
    public var source: String?
    public var playing: Bool
    public var style: VisualizerStyle
    public var placement: VisualizerPlacement
    /// One to three hex colors, e.g. from the album art.
    public var colors: [String]
    public var opacity: Float
    public var bars: Int

    public init(source: String?, playing: Bool, style: VisualizerStyle, placement: VisualizerPlacement,
                colors: [String], opacity: Float = 1, bars: Int = 32)
    {
        self.source = source
        self.playing = playing
        self.style = style
        self.placement = placement
        self.colors = colors
        self.opacity = opacity
        self.bars = bars
    }
}

/// A Metal view that pulls audio from `AudioFrameHub` once per frame, runs
/// it through `CavaAnalyzer` and draws. It never touches SwiftUI state, so
/// a frame redraws only this layer. Runs at 30 fps on the bar and 60 in the
/// popover, and stops when paused and settled, hidden, or out of a window.
@MainActor
public final class VisualizerView: MTKView, MTKViewDelegate {
    public private(set) var config: VisualizerConfig
    private var analyzer: CavaAnalyzer
    private let renderer: VisualizerRenderer?
    private var lastTime: CFTimeInterval = 0
    private var occlusionObserver: NSObjectProtocol?
    /// Our own display link, in `.common` mode so frames keep coming while
    /// the mouse is tracking or SwiftUI is busy (MTKView's loop stalls then).
    private var link: CADisplayLink?
    /// The popover's window reports itself occluded until it has ordered
    /// in, so assume a new window is visible until it says otherwise.
    private var visible = false

    public init(config: VisualizerConfig) {
        self.config = config
        analyzer = CavaAnalyzer(bars: config.bars)
        let device = VisualizerRenderer.device
        renderer = device.flatMap { VisualizerRenderer(device: $0) }
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        layer?.isOpaque = false
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        apply(config, force: true)
    }

    required init(coder: NSCoder) { fatalError() }

    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Updates from SwiftUI; cheap when nothing changed.
    public func apply(_ c: VisualizerConfig, force: Bool = false) {
        guard force || c != config else { return }
        if c.bars != config.bars || c.source != config.source { analyzer = CavaAnalyzer(bars: c.bars) }
        if c.style != config.style || c.placement != config.placement { renderer?.reset() }
        config = c
        let fps = Float(c.placement == .popup ? 60 : 30)
        preferredFramesPerSecond = Int(fps)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        renderer?.setColors(c.colors)
        wake()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        link?.invalidate()
        link = nil
        visible = window != nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let w = self.window else { return }
                    self.visible = w.occlusionState.contains(.visible)
                    self.wake()
                }
            }
            let l = displayLink(target: self, selector: #selector(tick))
            let fps = Float(preferredFramesPerSecond)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
            l.isPaused = true
            l.add(to: .main, forMode: .common)
            link = l
        }
        wake()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if link?.isPaused ?? true, visible, newSize.width > 0 { draw() }
    }

    @objc private func tick(_ l: CADisplayLink) { draw() }

    /// Runs the loop while there's something to show and someone to see it.
    private func wake() {
        let run = visible && (config.playing || !analyzer.isSettled)
        if run, link?.isPaused ?? true { lastTime = 0 }
        link?.isPaused = !run
        if !run, visible { draw() } // leave a settled frame
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let renderer, drawableSize.width > 0, drawableSize.height > 0, renderer.beginFrame() else { return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0 / Double(preferredFramesPerSecond) : min(now - lastTime, 0.1)
        lastTime = now
        analyzer.update(source: config.source, playing: config.playing, dt: dt,
                        fakeWhenMissing: config.placement != .row)
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else {
            renderer.cancelFrame()
            return
        }
        renderer.draw(analyzer.bars, dt: dt, config: config, pass: pass, drawable: drawable,
                      viewport: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                      scale: Float(window?.backingScaleFactor ?? 2))
        if !config.playing, analyzer.isSettled { link?.isPaused = true }
    }
}

/// Draws ridgelines or bars. Pipelines are built once per device.
@MainActor
final class VisualizerRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    private static var cache: Pipelines?

    struct Pipelines {
        let fill, glow, line, bars: MTLRenderPipelineState
        let writeDepth, testDepth, noDepth: MTLDepthStencilState
    }

    /// Matches `Uniforms` in the shader.
    struct Uniforms {
        var mvp = matrix_identity_float4x4
        var c0 = SIMD4<Float>(1, 1, 1, 1)
        var c1 = SIMD4<Float>(1, 1, 1, 1)
        var c2 = SIMD4<Float>(1, 1, 1, 1)
        var viewport = SIMD2<Float>(1, 1)
        var width: Float = 1
        var height: Float = 1
        var gap: Float = 0.2
        var lineWidth: Float = 2
        var rows: UInt32 = 1
        var points: UInt32 = 64
        var head: UInt32 = 0
        var opacity: Float = 1
    }

    /// Camera and size of the ridge field per placement.
    struct Ridge {
        var fov: Float, eye: SIMD3<Float>, target: SIMD3<Float>
        var rows: Int, gap: Float, width: Float, height: Float, lineWidth: Float, glow: Bool

        static func `for`(_ p: VisualizerPlacement) -> Ridge {
            switch p {
            case .bar: Ridge(fov: 26, eye: [0, 1.0, 3.2], target: [0, 0.62, -1.4], rows: 18, gap: 0.22, width: 7.6, height: 1.5, lineWidth: 1, glow: true)
            case .popup: Ridge(fov: 32, eye: [0, 1.45, 3.3], target: [0, 0.25, -2.2], rows: 30, gap: 0.19, width: 6.0, height: 1.25, lineWidth: 1, glow: true)
            case .row: Ridge(fov: 26, eye: [0, 1.0, 3.2], target: [0, 0.62, -1.4], rows: 8, gap: 0.3, width: 7.6, height: 1.5, lineWidth: 0.75, glow: false)
            }
        }
    }

    static let points = 64
    /// New ridges per second, whatever the frame rate.
    static let rowRate: Double = 30

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: Pipelines
    private var buffers: [MTLBuffer] = []
    private var frame = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var history: [Float] = []
    private var rows = 0
    private var head = 0
    private var rowClock: Double = 0
    private var colors: [SIMD4<Float>] = [[1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1]]

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(), let p = Self.pipelines(device) else { return nil }
        self.device = device
        self.queue = queue
        pipelines = p
    }

    func reset() { rows = 0 }

    /// Takes a slot for one frame, or false when the GPU is still behind;
    /// the caller skips the frame instead of blocking the main thread.
    func beginFrame() -> Bool { inFlight.wait(timeout: .now()) == .success }
    func cancelFrame() { inFlight.signal() }

    func setColors(_ hex: [String]) { colors = Self.stops(hex) }

    func draw(_ bars: [Float], dt: Double, config: VisualizerConfig, pass: MTLRenderPassDescriptor,
              drawable: MTLDrawable, viewport: SIMD2<Float>, scale: Float)
    {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment?.loadAction = .clear
        pass.depthAttachment?.clearDepth = 1
        guard let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            switch config.style {
            case .ridgeline: drawRidges(bars, dt: dt, config: config, enc: enc, viewport: viewport, scale: scale)
            case .bars: drawBars(bars, config: config, enc: enc, viewport: viewport)
            case .off: break
            }
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Ridgeline

    private func drawRidges(_ bars: [Float], dt: Double, config: VisualizerConfig, enc: MTLRenderCommandEncoder,
                            viewport: SIMD2<Float>, scale: Float)
    {
        let r = Ridge.for(config.placement)
        let p = Self.points
        if rows != r.rows {
            rows = r.rows
            history = [Float](repeating: 0, count: rows * p)
            head = 0
            rowClock = 0
            let len = history.count * MemoryLayout<Float>.stride
            buffers = (0..<3).compactMap { _ in device.makeBuffer(length: len, options: .storageModeShared) }
        }
        // Push a new ridge at a steady rate; ease the front one in between.
        rowClock += dt
        let ridge = Self.mirrored(Monstercat.apply(bars), points: p)
        if rowClock >= 1 / Self.rowRate {
            rowClock = rowClock.truncatingRemainder(dividingBy: 1 / Self.rowRate)
            head = (head + rows - 1) % rows
        }
        history.replaceSubrange(head * p..<(head + 1) * p, with: ridge)
        guard buffers.count == 3 else { return }
        let buf = buffers[frame % 3]
        frame += 1
        history.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        let mvp = Self.fitted(r, aspect: viewport.x / max(viewport.y, 1), margin: SIMD2(4, 4) / viewport * 2)
        var u = Uniforms(mvp: mvp, c0: colors[0], c1: colors[1], c2: colors[2], viewport: viewport,
                         width: r.width, height: r.height, gap: r.gap, lineWidth: r.lineWidth * scale,
                         rows: UInt32(rows), points: UInt32(p), head: UInt32(head), opacity: config.opacity)
        let stride = MemoryLayout<Uniforms>.stride
        enc.setVertexBytes(&u, length: stride, index: 0)
        enc.setFragmentBytes(&u, length: stride, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)

        // 1. Each ridge's silhouette, depth only, so ridges hide the ones behind.
        enc.setRenderPipelineState(pipelines.fill)
        enc.setDepthStencilState(pipelines.writeDepth)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: p * 2, instanceCount: rows)
        // 2. A soft glow under the front ridge.
        if r.glow {
            enc.setRenderPipelineState(pipelines.glow)
            enc.setDepthStencilState(pipelines.noDepth)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: p * 2, instanceCount: 1)
        }
        // 3. The ridge lines, as screen-space ribbons.
        enc.setRenderPipelineState(pipelines.line)
        enc.setDepthStencilState(pipelines.testDepth)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: p * 2, instanceCount: rows)
    }

    // MARK: Bars

    private func drawBars(_ bars: [Float], config: VisualizerConfig, enc: MTLRenderCommandEncoder, viewport: SIMD2<Float>) {
        var u = Uniforms(c0: colors[0], c1: colors[1], c2: colors[2], viewport: viewport,
                         points: UInt32(bars.count), opacity: config.opacity)
        var levels = bars.isEmpty ? [0] : bars
        enc.setRenderPipelineState(pipelines.bars)
        enc.setDepthStencilState(pipelines.noDepth)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setVertexBytes(&levels, length: levels.count * MemoryLayout<Float>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: levels.count)
    }

    // MARK: Helpers

    /// Bass in the middle, treble at both edges, tapering to nothing.
    static func mirrored(_ bars: [Float], points: Int) -> [Float] {
        let n = bars.count
        guard n > 0, points > 1 else { return [Float](repeating: 0, count: points) }
        return (0..<points).map { i in
            let u = abs(Float(i) / Float(points - 1) * 2 - 1)
            let f = u * Float(n - 1)
            let a = Int(f), t = f - Float(a)
            let lo = bars[a], hi = bars[min(n - 1, a + 1)]
            let v = lo + (hi - lo) * (t * t * (3 - 2 * t))
            return v * pow(1 - u, 0.35) * (0.35 + 0.65 * (1 - u * u * 0.4))
        }
    }

    /// Three gradient stops from one to three colors. One color gets two
    /// neighbours by turning its hue a little each way.
    static func stops(_ hex: [String]) -> [SIMD4<Float>] {
        func v(_ c: RGBA) -> SIMD4<Float> { [Float(c.r), Float(c.g), Float(c.b), 1] }
        let cs = hex.compactMap { RGBA(hex: $0) }
        switch cs.count {
        case 0: return [[0.8, 0.65, 0.97, 1], [0.54, 0.71, 0.98, 1], [0.96, 0.76, 0.91, 1]]
        case 1:
            let c = NSColor(srgbRed: cs[0].r, green: cs[0].g, blue: cs[0].b, alpha: 1)
            func turn(_ dh: CGFloat, _ db: CGFloat) -> SIMD4<Float> {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                let o = NSColor(hue: (h + dh + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: min(1, b + db), alpha: 1)
                    .usingColorSpace(.sRGB) ?? c
                return [Float(o.redComponent), Float(o.greenComponent), Float(o.blueComponent), 1]
            }
            return [v(cs[0]), turn(0.08, 0.1), turn(-0.09, 0.05)]
        case 2:
            let m = RGBA(r: (cs[0].r + cs[1].r) / 2, g: (cs[0].g + cs[1].g) / 2, b: (cs[0].b + cs[1].b) / 2)
            return [v(cs[0]), v(m), v(cs[1])]
        default: return [v(cs[0]), v(cs[1]), v(cs[2])]
        }
    }

    /// The camera for `r`, then scaled and centered on screen so the whole
    /// ridge field at full height fits inside the view, `margin` (in NDC)
    /// from every edge, whatever the view's shape.
    static func fitted(_ r: Ridge, aspect: Float, margin: SIMD2<Float>) -> simd_float4x4 {
        let mvp = perspective(fovY: r.fov * .pi / 180, aspect: aspect, near: 0.1, far: 50)
            * lookAt(eye: r.eye, target: r.target, up: [0, 1, 0])
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for z in [0, -Float(r.rows - 1) * r.gap] {
            for x in [-r.width / 2, r.width / 2] {
                for y in [0, r.height] {
                    let p = mvp * SIMD4(x, y, z, 1)
                    let n = SIMD2(p.x, p.y) / p.w
                    lo = simd_min(lo, n)
                    hi = simd_max(hi, n)
                }
            }
        }
        let room = SIMD2<Float>(repeating: 2) - margin * 2
        let size = simd_max(hi - lo, SIMD2(repeating: 1e-4))
        let s = min(room.x / size.x, room.y / size.y)
        let center = (lo + hi) / 2
        let t = -center * s
        let fit = simd_float4x4(columns: ([s, 0, 0, 0], [0, s, 0, 0], [0, 0, 1, 0], [t.x, t.y, 0, 1]))
        return fit * mvp
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: ([x, 0, 0, 0], [0, y, 0, 0], [0, 0, z, -1], [0, 0, z * near, 0]))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target), x = normalize(cross(up, z)), y = cross(z, x)
        return simd_float4x4(columns: ([x.x, y.x, z.x, 0], [x.y, y.y, z.y, 0], [x.z, y.z, z.z, 0],
                                       [-dot(x, eye), -dot(y, eye), -dot(z, eye), 1]))
    }

    private static func pipelines(_ device: MTLDevice) -> Pipelines? {
        if let cache { return cache }
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            func pso(_ vertex: String, _ fragment: String, colorWrite: Bool = true) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: vertex)
                d.fragmentFunction = lib.makeFunction(name: fragment)
                d.depthAttachmentPixelFormat = .depth32Float
                let c = d.colorAttachments[0]!
                c.pixelFormat = .bgra8Unorm
                if colorWrite {
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .one
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                } else {
                    c.writeMask = []
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
                let d = MTLDepthStencilDescriptor()
                d.depthCompareFunction = compare
                d.isDepthWriteEnabled = write
                return device.makeDepthStencilState(descriptor: d)
            }
            guard let w = depth(.less, write: true), let t = depth(.lessEqual, write: false), let n = depth(.always, write: false) else { return nil }
            let p = Pipelines(fill: try pso("fill_vertex", "fill_fragment", colorWrite: false),
                              glow: try pso("glow_vertex", "glow_fragment"),
                              line: try pso("line_vertex", "line_fragment"),
                              bars: try pso("bars_vertex", "bars_fragment"),
                              writeDepth: w, testDepth: t, noDepth: n)
            cache = p
            return p
        } catch {
            NSLog("gizmobar: visualizer shaders failed: \(error)")
            return nil
        }
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 mvp;
        float4 c0, c1, c2;
        float2 viewport;
        float width, height, gap, lineWidth;
        uint rows, points, head;
        float opacity;
    };

    static float3 pal(constant Uniforms& u, float t) {
        t = clamp(t, 0.0, 1.0);
        return t < 0.5 ? mix(u.c0.rgb, u.c1.rgb, t * 2.0) : mix(u.c1.rgb, u.c2.rgb, t * 2.0 - 1.0);
    }

    static float3 ridgePoint(constant Uniforms& u, const device float* h, uint row, uint p) {
        uint slot = (u.head + row) % u.rows;
        float x = (float(p) / float(u.points - 1) - 0.5) * u.width;
        return float3(x, h[slot * u.points + p] * u.height, -float(row) * u.gap);
    }

    struct Plain { float4 pos [[position]]; };

    vertex Plain fill_vertex(uint vid [[vertex_id]], uint row [[instance_id]],
                             constant Uniforms& u [[buffer(0)]], const device float* h [[buffer(1)]]) {
        float3 w = ridgePoint(u, h, row, vid / 2);
        if (vid % 2 == 0) w.y = -1.0;
        w.z -= 0.004; // just behind its own line
        Plain o; o.pos = u.mvp * float4(w, 1.0); return o;
    }
    fragment float4 fill_fragment(Plain in [[stage_in]]) { return float4(0.0); }

    struct Glow { float4 pos [[position]]; float3 color; float v; };

    vertex Glow glow_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]], const device float* h [[buffer(1)]]) {
        uint p = vid / 2;
        float3 w = ridgePoint(u, h, 0, p);
        bool top = vid % 2 == 1;
        if (!top) w.y = 0.0;
        Glow o;
        o.pos = u.mvp * float4(w, 1.0);
        o.color = pal(u, abs(float(p) / float(u.points - 1) * 2.0 - 1.0) * 0.9);
        o.v = top ? 1.0 : 0.0;
        return o;
    }
    fragment float4 glow_fragment(Glow in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float a = in.v * in.v * 0.38 * u.opacity;
        return float4(in.color * a, a * 0.7);
    }

    struct Line { float4 pos [[position]]; float3 color; float edge; float alpha; };

    vertex Line line_vertex(uint vid [[vertex_id]], uint row [[instance_id]],
                            constant Uniforms& u [[buffer(0)]], const device float* h [[buffer(1)]]) {
        uint p = vid / 2;
        float side = (vid % 2 == 0) ? -1.0 : 1.0;
        uint pa = p == 0 ? 0 : p - 1;
        uint pb = min(p + 1, u.points - 1);
        float4 c = u.mvp * float4(ridgePoint(u, h, row, p), 1.0);
        float4 a = u.mvp * float4(ridgePoint(u, h, row, pa), 1.0);
        float4 b = u.mvp * float4(ridgePoint(u, h, row, pb), 1.0);
        float2 half_vp = u.viewport * 0.5;
        float2 d = b.xy / b.w * half_vp - a.xy / a.w * half_vp;
        float2 dir = length(d) > 1e-4 ? normalize(d) : float2(1.0, 0.0);
        float2 n = float2(-dir.y, dir.x);
        float extent = u.lineWidth * 0.5 + 1.0; // +1 px to antialias
        Line o;
        o.pos = c;
        o.pos.xy += n * side * extent / half_vp * c.w;
        float t = float(row) / float(u.rows);
        float uu = abs(float(p) / float(u.points - 1) * 2.0 - 1.0);
        o.color = pal(u, uu * 0.9 + t * 0.3);
        o.alpha = pow(1.0 - t, 1.6) * (row == 0 ? 1.0 : 0.75) * u.opacity;
        o.edge = side * extent;
        return o;
    }
    fragment float4 line_fragment(Line in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float a = clamp(u.lineWidth * 0.5 + 0.5 - abs(in.edge), 0.0, 1.0) * in.alpha;
        return float4(in.color * a, a);
    }

    struct Bar { float4 pos [[position]]; float3 color; };

    vertex Bar bars_vertex(uint vid [[vertex_id]], uint i [[instance_id]],
                           constant Uniforms& u [[buffer(0)]], constant float* levels [[buffer(1)]]) {
        float n = float(u.points);
        float w = 2.0 / n;
        float x0 = -1.0 + w * (float(i) + 0.15), x1 = x0 + w * 0.7;
        float minH = 2.0 / max(u.viewport.y, 1.0) * 2.0;
        float top = -1.0 + max(minH, clamp(levels[i], 0.0, 1.0) * 2.0);
        float2 corner = float2((vid & 1) ? x1 : x0, (vid & 2) ? top : -1.0);
        Bar o;
        o.pos = float4(corner, 0.0, 1.0);
        o.color = pal(u, float(i) / max(n - 1.0, 1.0));
        return o;
    }
    fragment float4 bars_fragment(Bar in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        return float4(in.color * u.opacity, u.opacity);
    }
    """
}
#endif
