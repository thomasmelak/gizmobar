import AppKit
import SwiftUI
import GizmoCore

/// Previous, play/pause and next, then the track over a dimmed spectrum, in
/// one pill (hidden when nothing is loaded). Click the track for the Now
/// Playing popover; right-click play/pause skips to the next track.
struct NowPlayingWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if let source = store.snapshot.nowPlaying.current, let track = source.track {
            let t = store.theme
            let tint = track.artColor ?? t.accent
            Pill(focused: showing, hovered: hovering) {
                HStack(spacing: 2) {
                    MediaButton(symbol: "backward.fill", size: 10) { store.request(BarRequest.mediaPrevious) }
                    MediaButton(symbol: source.isPlaying ? "pause.fill" : "play.fill", size: 13,
                                onRightClick: { store.request(BarRequest.mediaNext) }) {
                        store.request(BarRequest.mediaToggle)
                    }
                    MediaButton(symbol: "forward.fill", size: 10) { store.request(BarRequest.mediaNext) }
                    ZStack {
                        SpectrumBars(playing: source.isPlaying, color: tint, opacity: 0.32)
                        Marquee(text: track.line, scrolling: hovering)
                            .font(.custom(t.font, size: t.fontSize))
                            .foregroundStyle(Color(hex: t.label))
                            .id(track.key)
                            .transition(.opacity)
                    }
                    .frame(width: store.config.media.width)
                    .padding(.leading, 6)
                    .barAction(onHover: { hovering = $0 }) { showing.toggle() }
                }
                .animation(.easeInOut(duration: 0.35), value: track.key)
            }
            .barPopover(id: "now_playing", isPresented: $showing) { NowPlayingPopover() }
        }
    }
}

private struct MediaButton: View {
    let symbol: String
    var size: CGFloat
    var onRightClick: (@MainActor () -> Void)?
    let action: @MainActor () -> Void
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(Color(hex: hovering ? t.accent : t.icon))
            .frame(width: 20, height: 20)
            .contentTransition(.symbolEffect(.replace))
            .barAction(onHover: { hovering = $0 }, action)
            .overlay { if let onRightClick { RightClickArea(action: onRightClick) } }
    }
}

/// Text that scrolls when it doesn't fit, only while hovered (no work
/// otherwise); truncated with a fade at rest.
struct Marquee: View {
    let text: String
    var scrolling: Bool
    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth - geo.size.width
            Group {
                if scrolling && overflow > 0 {
                    TimelineView(.animation) { tl in
                        let gap: CGFloat = 40
                        let cycle = textWidth + gap
                        let x = CGFloat(tl.date.timeIntervalSince(start) * 30).truncatingRemainder(dividingBy: cycle)
                        HStack(spacing: gap) { label; label }
                            .offset(x: -x)
                    }
                    .onAppear { start = Date() }
                } else {
                    label.frame(maxWidth: .infinity, alignment: overflow > 0 ? .leading : .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .mask(fade(overflow > 0))
        }
    }

    private var label: some View {
        Text(text).lineLimit(1).fixedSize()
            .background(GeometryReader { g in Color.clear.onAppear { textWidth = g.size.width }.onChange(of: text) { textWidth = g.size.width } })
    }

    private func fade(_ on: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: on ? 0.88 : 1),
            .init(color: .black.opacity(on ? 0 : 1), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

/// Spectrum bars: live levels from the audio tap, or eased random levels
/// (like visualizer.sh) when there's no tap. Draws nothing while paused.
struct SpectrumBars: View {
    let playing: Bool
    let color: String
    var opacity: Double = 1
    @Environment(BarStore.self) private var store
    @State private var fake: [Float] = []

    var body: some View {
        let live = store.snapshot.spectrum
        let count = store.config.media.bands
        Group {
            if !playing {
                bars(Array(repeating: 0, count: count))
            } else if !live.isEmpty {
                bars(live)
            } else {
                TimelineView(.periodic(from: .now, by: 0.12)) { tl in
                    bars(fake).onChange(of: tl.date) { fake = Self.step(fake, count: count) }
                }
            }
        }
        .opacity(opacity)
    }

    private func bars(_ levels: [Float]) -> some View {
        Canvas { ctx, size in
            guard !levels.isEmpty else { return }
            let w = size.width / CGFloat(levels.count)
            for (i, l) in levels.enumerated() {
                let h = max(2, size.height * CGFloat(l))
                let r = CGRect(x: CGFloat(i) * w + w * 0.15, y: size.height - h, width: w * 0.7, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: min(1.5, w * 0.35)), with: .color(Color(hex: color)))
            }
        }
    }

    /// Eases toward random targets; middle bars reach higher.
    static func step(_ levels: [Float], count: Int) -> [Float] {
        let prev = levels.count == count ? levels : Array(repeating: 0, count: count)
        let mid = Float(count) / 2
        return prev.enumerated().map { i, p in
            let reach = 0.45 + 0.5 * (1 - abs(Float(i) - mid) / mid)
            let target = Float.random(in: 0...reach)
            return (p + target * 2) / 3
        }
    }
}

/// Catches right clicks only; left clicks and hover pass through.
struct RightClickArea: NSViewRepresentable {
    let action: @MainActor () -> Void

    final class View: NSView {
        var action: (@MainActor () -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { MainActor.assumeIsolated { action?() } }
    }

    func makeNSView(context: Context) -> View { let v = View(); v.action = action; return v }
    func updateNSView(_ v: View, context: Context) { v.action = action }
}

struct NowPlayingPopover: View {
    @Environment(BarStore.self) private var store
    @State private var sourcesOpen = false

    var body: some View {
        let t = store.theme
        let np = store.snapshot.nowPlaying
        if let source = np.current, let track = source.track {
            let tint = track.artColor ?? t.accent
            VStack(alignment: .leading, spacing: 10) {
                PopupHeader(icon: "music.note", title: "Now Playing", action: {
                    PopoverController.shared.close()
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.id) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                })
                if np.sources.count > 1 {
                    PopupRow(icon: sourcesOpen ? "chevron.up" : "chevron.down", text: source.name, color: t.label) {
                        sourcesOpen.toggle()
                    }
                    if sourcesOpen {
                        ForEach(np.sources) { s in
                            PopupRow(icon: s.isPlaying ? "play.fill" : "pause.fill", text: s.track?.line ?? s.name,
                                     color: s.id == source.id ? t.accent : nil, iconColor: s.id == source.id ? t.accent : t.label,
                                     action: { store.request(BarRequest.mediaSelect(s.id)); sourcesOpen = false })
                        }
                    }
                }
                ArtView(path: track.artworkPath, key: track.key, tint: tint) {
                    store.request(BarRequest.mediaToggle)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.custom(t.font, size: t.fontSize + 2).bold()).lineLimit(2)
                    if !track.artist.isEmpty { Text(track.artist).foregroundStyle(Color(hex: tint)).lineLimit(1) }
                    if !track.album.isEmpty { Text(track.album).foregroundStyle(Color(hex: t.label).opacity(0.7)).lineLimit(1) }
                }
                .id(track.key)
                .transition(.opacity)
                Scrubber(source: source, tint: tint)
                Controls(source: source, tint: tint)
                SpectrumBars(playing: source.isPlaying, color: tint).frame(height: 28)
            }
            .frame(width: 260)
            .animation(.easeInOut(duration: 0.35), value: track.key)
        }
    }
}

/// Album art that crossfades between tracks and tilts toward the pointer.
private struct ArtView: View {
    let path: String?
    let key: String
    let tint: String
    let onTap: @MainActor () -> Void
    @State private var tilt: CGSize = .zero

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(hex: tint).opacity(0.25))
            if let path, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .id(key)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Color(hex: tint))
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color(hex: tint).opacity(0.45), radius: 18, y: 6)
        .rotation3DEffect(.degrees(Double(tilt.height) * 10), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(Double(-tilt.width) * 10), axis: (x: 0, y: 1, z: 0))
        .animation(.easeOut(duration: 0.2), value: tilt)
        .animation(.easeInOut(duration: 0.4), value: key)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): tilt = CGSize(width: (p.x - 110) / 110, height: (p.y - 110) / 110)
            case .ended: tilt = .zero
            }
        }
        .barAction(onTap)
    }
}

private struct Scrubber: View {
    let source: MediaSource
    let tint: String
    @Environment(BarStore.self) private var store

    var body: some View {
        if let duration = source.track?.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: source.isPlaying ? 1 : 3600)) { tl in
                let pos = source.position(at: tl.date) ?? 0
                VStack(spacing: 2) {
                    BarSlider(value: pos / duration, tint: tint, gradient: source.track?.artGradient,
                              commitOnRelease: true) { v in
                        store.request(BarRequest.mediaSeek(v * duration))
                    }
                    HStack {
                        Text(Self.time(pos))
                        Spacer()
                        Text("-" + Self.time(duration - pos))
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color(hex: store.theme.label).opacity(0.7))
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct Controls: View {
    let source: MediaSource
    let tint: String
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        HStack {
            if let shuffle = source.shuffle {
                ControlButton(symbol: "shuffle", size: 13, color: shuffle ? tint : t.icon) { store.request(BarRequest.mediaShuffle) }
            } else { Spacer().frame(width: 28) }
            Spacer()
            ControlButton(symbol: "backward.fill", size: 16, color: t.label) { store.request(BarRequest.mediaPrevious) }
            ControlButton(symbol: source.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 34, color: tint) {
                store.request(BarRequest.mediaToggle)
            }
            ControlButton(symbol: "forward.fill", size: 16, color: t.label) { store.request(BarRequest.mediaNext) }
            Spacer()
            if let r = source.repeatMode {
                ControlButton(symbol: r == .one ? "repeat.1" : "repeat", size: 13, color: r == .off ? t.icon : tint) {
                    store.request(BarRequest.mediaRepeat)
                }
            } else { Spacer().frame(width: 28) }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let color: String
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(Color(hex: color))
            .scaleEffect(hovering ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .frame(width: max(28, size + 6), height: max(28, size + 6))
            .contentTransition(.symbolEffect(.replace))
            .barAction(onHover: { hovering = $0 }, action)
    }
}
