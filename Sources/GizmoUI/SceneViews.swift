import AppKit
import RealityKit
import SwiftUI
import GizmoCore
import GizmoScene

// MARK: - Dot globe

/// The built-in dot globe: land dots lit by the real sun, markers that can
/// pulse. Draws once when still; animates at 30 fps only while it spins or
/// a marker pulses.
struct GlobeView: View {
    var size: CGFloat
    var markers: [GlobeMarker]
    var spin: Double
    var showLabels = false
    var draggable = false
    @Environment(BarStore.self) private var store
    @State private var drag: Double = 0
    @State private var dragStart: Double?
    @State private var start = Date()

    private var dots: [SIMD2<Double>] { GlobeMath.landDots(step: size < 60 ? 2 : 1) }

    var body: some View {
        let animate = spin != 0 || markers.contains(where: \.pulse)
        Group {
            if animate {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in canvas(tl.date) }
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { tl in canvas(tl.date) }
            }
        }
        .frame(width: size, height: size)
        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
            guard draggable else { return }
            if dragStart == nil { dragStart = drag }
            drag = (dragStart ?? 0) - Double(g.translation.width) / Double(size) * 180
        }.onEnded { _ in dragStart = nil })
    }

    private func canvas(_ date: Date) -> some View {
        let t = store.theme
        let sun = GlobeMath.subsolarPoint(at: date)
        let elapsed = date.timeIntervalSince(start)
        // Faces the local longitude by default.
        let home = Double(TimeZone.current.secondsFromGMT()) / 3600 * 15
        let center = home + drag + spin * elapsed
        let dots = self.dots
        let markers = self.markers
        let labels = showLabels
        return Canvas { ctx, sz in
            let r = min(sz.width, sz.height) / 2 - 1
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(hex: t.itemBackground).opacity(0.6)))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(hex: t.itemBorder)), lineWidth: 0.75)
            let dot = max(0.9, r / 28)
            let day = Color(hex: t.label), night = Color(hex: t.icon)
            for d in dots {
                let p = GlobeMath.project(lat: d.x, lon: d.y, centerLon: center)
                guard p.z > 0 else { continue }
                let light = GlobeMath.daylight(lat: d.x, lon: d.y, sun: sun)
                let x = c.x + CGFloat(p.x) * r, y = c.y - CGFloat(p.y) * r
                let s = dot * (0.6 + 0.4 * CGFloat(p.z))
                ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                         with: .color((light > 0.5 ? day : night).opacity(0.35 + 0.55 * light * p.z + 0.1)))
            }
            for m in markers {
                let p = GlobeMath.project(lat: m.lat, lon: m.lon, centerLon: center)
                guard p.z > 0 else { continue }
                let x = c.x + CGFloat(p.x) * r, y = c.y - CGFloat(p.y) * r
                let color = Color(hex: PluginNode.color(m.color, theme: ["accent": t.accent, "good": t.good, "warn": t.warn, "bad": t.bad]) ?? t.accent)
                let s = max(2.5, r / 9)
                if m.pulse {
                    let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.6) / 1.6)
                    let ring = s * (1 + 2.2 * phase)
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - ring / 2, y: y - ring / 2, width: ring, height: ring)),
                               with: .color(color.opacity(Double(1 - phase))), lineWidth: 1)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)), with: .color(color))
                if labels, let label = m.label {
                    ctx.draw(Text(label).font(.system(size: 10)).foregroundStyle(Color(hex: t.label)), at: CGPoint(x: x + s, y: y), anchor: .leading)
                }
            }
        }
    }
}

/// `globe` in the layout: the dot globe with a marker for here and for
/// each world clock. Click for a large globe you can drag.
struct GlobeWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    private var markers: [GlobeMarker] {
        var out: [GlobeMarker] = []
        if let here = GlobeMath.zoneCoordinates[TimeZone.current.identifier] {
            out.append(GlobeMarker(lat: here.lat, lon: here.lon, color: "theme.accent", pulse: false, label: "Here"))
        }
        for w in store.config.clock.world {
            if let p = GlobeMath.zoneCoordinates[w.zone] {
                out.append(GlobeMarker(lat: p.lat, lon: p.lon, color: "theme.good", label: w.label ?? w.zone.split(separator: "/").last.map(String.init)))
            }
        }
        return out
    }

    var body: some View {
        Pill(focused: showing, hovered: hovering) {
            GlobeView(size: store.config.bar.height - store.config.bar.margin * 2 - 6, markers: markers, spin: 0)
        }
        .barAction(onHover: { hovering = $0 }) { showing.toggle() }
        .barPopover(id: "globe", isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                PopupHeader(icon: "globe", title: "World")
                GlobeView(size: 240, markers: markers, spin: 0, showLabels: true, draggable: true)
            }
        }
    }
}

// MARK: - 3D models

/// A RealityKit view for one model. Renders live only while something moves
/// (a clip, a spin, a drag); otherwise it swaps in a snapshot and takes the
/// RealityKit view out of the window, so a still model costs nothing.
struct ModelSceneView: NSViewRepresentable {
    let url: URL
    let options: SceneOptions
    var orbit = false
    var onClick: ((String?) -> Void)?
    var onLoaded: (([String]) -> Void)?
    /// Bumped by the plugin to play a clip once or change parts.
    var command: SceneCommand?

    func makeNSView(context: Context) -> ModelSceneHost {
        let v = ModelSceneHost()
        v.configure(url: url, options: options, orbit: orbit)
        v.onClick = onClick
        v.onLoaded = onLoaded
        return v
    }

    func updateNSView(_ v: ModelSceneHost, context: Context) {
        v.onClick = onClick
        v.onLoaded = onLoaded
        v.configure(url: url, options: options, orbit: orbit)
        if let command { v.apply(command) }
    }
}

/// A plugin's `ctx.scene.play/set` call.
public struct SceneCommand: Sendable, Equatable {
    public var seq: Int
    public var kind: String
    public var payload: JSONValue
    public init(seq: Int, kind: String, payload: JSONValue) { self.seq = seq; self.kind = kind; self.payload = payload }
}

@MainActor
final class ModelSceneHost: NSView {
    var onClick: ((String?) -> Void)?
    var onLoaded: (([String]) -> Void)?
    private var arView: ARView?
    private let still = NSImageView()
    private var scene: ModelScene?
    private var camera = PerspectiveCamera()
    private var url: URL?
    private var options: SceneOptions?
    private var orbit = false
    private var yawOffset: Float = 0
    private var dragStartX: CGFloat?
    private var timer: Timer?
    private var clipTime: Float = 0
    private var currentClip: String?
    private var previous: (clip: String, time: Float)?
    private var blendLeft: Float = 0
    private var blendTotal: Float = 0
    private var onceReturn: String?
    private var lastSeq = -1
    private var idleSince = Date()
    private var spinAngle: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        still.imageScaling = .scaleProportionallyUpOrDown
        still.frame = bounds
        still.autoresizingMask = [.width, .height]
        addSubview(still)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(url: URL, options: SceneOptions, orbit: Bool) {
        let reload = url != self.url || options.look != self.options?.look
        let clipChanged = options.clip != self.options?.clip
        self.options = options
        self.orbit = orbit
        if reload {
            self.url = url
            load()
        } else if clipChanged, let clip = options.clip {
            transition(to: clip, blend: Float(options.blend))
        }
        if let scene { for (name, o) in options.parts { scene.apply(part: name, o) } }
        wake()
    }

    private func load() {
        guard let url, let options else { return }
        do {
            let s = try ModelScene.load(url, look: options.look)
            scene = s
            let view = arView ?? makeARView()
            view.scene.anchors.removeAll()
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(s.root)
            camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 30
            anchor.addChild(camera)
            let light = DirectionalLight()
            light.light.intensity = 2500
            light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
            anchor.addChild(light)
            view.scene.addAnchor(anchor)
            placeCamera()
            currentClip = nil
            if let clip = options.clip ?? s.clips.first { transition(to: clip, blend: 0) }
            onLoaded?(s.clips)
        } catch {
            NSLog("gizmobar: can't load \(url.lastPathComponent): \(error)")
            still.image = NSImage(systemSymbolName: "cube.transparent", accessibilityDescription: nil)
        }
    }

    private func makeARView() -> ARView {
        let v = ARView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.environment.background = .color(.clear)
        v.layer?.isOpaque = false
        arView = v
        return v
    }

    private func placeCamera() {
        guard let scene, let options else { return }
        let yaw = (Float(options.yaw) + yawOffset + spinAngle) * .pi / 180
        let distance = scene.radius / sin(15 * .pi / 180) * 1.05
        let pos = scene.center + SIMD3(sin(yaw) * distance, scene.radius * 0.25, cos(yaw) * distance)
        camera.look(at: scene.center, from: pos, relativeTo: nil)
    }

    // MARK: Playback

    func apply(_ c: SceneCommand) {
        guard c.seq != lastSeq else { return }
        lastSeq = c.seq
        switch c.kind {
        case "scene.play":
            guard let clip = c.payload["clip"]?.string else { return }
            let once: Bool = { if case .bool(let b)? = c.payload["once"] { return b }; return false }()
            let blend: Float = { if case .number(let n)? = c.payload["blend"] { return Float(n) }; return 0.25 }()
            onceReturn = once ? (currentClip ?? options?.clip) : nil
            transition(to: clip, blend: blend)
        case "scene.set":
            guard let part = c.payload["part"]?.string else { return }
            func num(_ v: JSONValue) -> Double? { if case .number(let n) = v { return n }; return nil }
            let visible: Bool? = { if case .bool(let b)? = c.payload["visible"] { return b }; return nil }()
            scene?.apply(part: part, PartOverride(visible: visible, color: c.payload["color"]?.string,
                                                 rotation: c.payload["rotation"]?.array?.compactMap(num)))
        default: break
        }
        wake()
    }

    private func transition(to clip: String, blend: Float) {
        guard let scene else { return }
        if scene.usesRealityKitAnimation {
            scene.playUSDZ(clip, loop: onceReturn == nil && (options?.loop ?? true), blend: Double(blend))
            currentClip = clip
            return
        }
        if let cur = currentClip, blend > 0 { previous = (cur, clipTime); blendLeft = blend; blendTotal = blend } else { previous = nil }
        currentClip = clip
        clipTime = 0
    }

    /// Starts the live view and the 30 fps loop until things settle.
    private func wake() {
        idleSince = Date()
        guard let arView else { return }
        if arView.superview == nil {
            arView.frame = bounds
            addSubview(arView)
        }
        still.isHidden = true
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(1 / 30) }
        }
    }

    private func tick(_ dt: Float) {
        guard let scene, let options else { return }
        var moving = dragStartX != nil || options.spin != 0 || blendLeft > 0
        if options.spin != 0 {
            spinAngle = (spinAngle + Float(options.spin) * dt).truncatingRemainder(dividingBy: 360)
            placeCamera()
        }
        if let clip = currentClip {
            let duration = scene.duration(of: clip)
            if scene.usesRealityKitAnimation {
                moving = moving || duration > 0
            } else if duration > 0 {
                clipTime += dt
                if clipTime >= duration {
                    if let back = onceReturn {
                        onceReturn = nil
                        transition(to: back, blend: 0.2)
                    } else if options.loop {
                        clipTime = clipTime.truncatingRemainder(dividingBy: duration)
                    } else {
                        clipTime = duration
                    }
                }
                if previous != nil, blendLeft > 0 {
                    blendLeft = max(0, blendLeft - dt)
                    previous?.time += dt
                }
                let w = blendTotal > 0 ? 1 - blendLeft / blendTotal : 1
                scene.pose(clip: currentClip ?? clip, time: clipTime, from: blendLeft > 0 ? previous : nil, weight: w)
                moving = moving || options.loop || clipTime < duration
            }
        }
        if moving { idleSince = Date() }
        // Still for a moment: freeze to a snapshot and stop rendering.
        if Date().timeIntervalSince(idleSince) > 0.5 { freeze() }
    }

    private func freeze() {
        timer?.invalidate()
        timer = nil
        guard let arView, arView.superview != nil else { return }
        arView.snapshot(saveToHDR: false) { [weak self] image in
            MainActor.assumeIsolated {
                guard let self, self.timer == nil else { return }
                if let image { self.still.image = image }
                self.still.isHidden = false
                arView.removeFromSuperview()
            }
        }
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        dragStartX = orbit ? event.locationInWindow.x : nil
        wake()
    }

    override func mouseDragged(with event: NSEvent) {
        guard orbit, let start = dragStartX else { return }
        yawOffset -= Float(event.locationInWindow.x - start) * 0.8
        dragStartX = event.locationInWindow.x
        placeCamera()
        wake()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        guard let arView, let scene else { onClick?(nil); return }
        if arView.superview == nil { addSubview(arView); arView.frame = bounds }
        let hit = arView.entity(at: arView.convert(event.locationInWindow, from: nil))
        onClick?(hit.flatMap { scene.partName(of: $0) })
        wake()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
}
