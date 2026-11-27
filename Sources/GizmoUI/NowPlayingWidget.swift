import AppKit
import SwiftUI
import GizmoCore

/// Previous, play/pause and next, then the track over a dimmed spectrum, in
/// one pill (hidden when nothing is loaded). Click the track for the Now
/// Playing popover; right-click play/pause skips to the next track. Apps
/// that make sound without being players (calls, videos, games) show their
/// icon and name over their own spectrum, with no controls.
struct NowPlayingWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        switch store.shownSource {
        case .media(let source)?:
            if let track = source.track {
                let tint = track.artColor ?? t.accent
                Pill(focused: showing, hovered: hovering) {
                    HStack(spacing: 2) {
                        HStack(spacing: 2) {
                            MediaButton(symbol: "backward.fill", size: 10) { store.request(BarRequest.mediaPrevious) }
                            MediaButton(symbol: source.isPlaying ? "pause.fill" : "play.fill", size: 13,
                                        onRightClick: { store.request(BarRequest.mediaNext) }) {
                                store.request(BarRequest.mediaToggle)
                            }
                            MediaButton(symbol: "forward.fill", size: 10) { store.request(BarRequest.mediaNext) }
                        }
                        .frame(width: Self.controlsWidth)
                        label(track.line, key: track.key, source: source.id, playing: source.isPlaying, tint: tint)
                            .padding(.leading, 6)
                    }
                    .animation(.easeInOut(duration: 0.35), value: track.key)
                }
                .barPopover(id: "now_playing", isPresented: $showing) { NowPlayingPopover() }
            }
        case .audio(let source)?:
            Pill(focused: showing, hovered: hovering) {
                // Same width as a player's pill, so switching sources doesn't
                // move the rest of the bar: the icon takes the controls' place.
                HStack(spacing: 2) {
                    AppIconView(app: AppRef(bundleID: source.id, name: source.name), size: 16)
                        .frame(width: Self.controlsWidth)
                    label(source.name, key: source.id, source: source.id, playing: source.isActive, tint: t.accent)
                        .padding(.leading, 6)
                }
            }
            .barPopover(id: "now_playing", isPresented: $showing) { NowPlayingPopover() }
        case nil:
            EmptyView()
        }
    }

    /// Three 20 pt buttons with 2 pt between them.
    static let controlsWidth: CGFloat = 64

    private func label(_ text: String, key: String, source: String, playing: Bool, tint: String) -> some View {
        let t = store.theme
        return ZStack {
            SpectrumBars(source: source, playing: playing, color: tint, opacity: 0.32)
            Marquee(text: text, scrolling: hovering)
                .font(.custom(t.font, size: t.fontSize))
                .foregroundStyle(Color(hex: t.label))
                .id(key)
                .transition(.opacity)
        }
        .frame(width: store.config.media.width)
        .barAction(onHover: { hovering = $0 }) { showing.toggle() }
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
    /// The audio source (app bundle ID) whose levels to draw.
    let source: String
    let playing: Bool
    let color: String
    var opacity: Double = 1
    @Environment(BarStore.self) private var store
    @State private var fake: [Float] = []

    var body: some View {
        let live = store.snapshot.spectra[source] ?? []
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

    var body: some View {
        let t = store.theme
        if let shown = store.shownSource {
            VStack(alignment: .leading, spacing: 10) {
                PopupHeader(icon: "music.note", title: "Now Playing", action: {
                    PopoverController.shared.close()
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shown.id) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                })
                SourceList(shown: shown.id)
                switch shown {
                case .media(let source):
                    if let track = source.track {
                        let tint = track.artColor ?? t.accent
                        ArtCarousel(source: source, track: track, tint: tint)
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
                        SpectrumBars(source: source.id, playing: source.isPlaying, color: tint).frame(height: 28)
                    }
                case .audio(let source):
                    VStack(spacing: 10) {
                        AppIconView(app: AppRef(bundleID: source.id, name: source.name), size: 96)
                        Text(source.name).font(.custom(t.font, size: t.fontSize + 2).bold()).lineLimit(1)
                        Text(source.isActive ? "Playing sound" : "Quiet")
                            .foregroundStyle(Color(hex: t.label).opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    SpectrumBars(source: source.id, playing: source.isActive, color: t.accent).frame(height: 40)
                }
            }
            .frame(width: 260)
            .animation(.easeInOut(duration: 0.35), value: shown.id)
        }
    }
}

/// Every player with a track and every app heard in the last 10 minutes,
/// playing ones first, each with a small live spectrum. Click to show it.
private struct SourceList: View {
    let shown: String
    @Environment(BarStore.self) private var store

    struct Row: Identifiable {
        let id: String
        let name: String
        let detail: String?
        let playing: Bool
        let isMedia: Bool
    }

    var rows: [Row] {
        let np = store.snapshot.nowPlaying
        let media = np.sources.filter { $0.track != nil }
        let mediaIDs = Set(media.map(\.id))
        let audio = store.snapshot.audioSources
        let active = Set(audio.filter(\.isActive).map(\.id))
        var out = media.map { m in
            Row(id: m.id, name: m.name, detail: m.track?.line, playing: m.isPlaying || active.contains(m.id), isMedia: true)
        }
        out += audio.filter { !mediaIDs.contains($0.id) }.map { a in
            Row(id: a.id, name: a.name, detail: a.isActive ? nil : Self.ago(a.lastHeard), playing: a.isActive, isMedia: false)
        }
        return out.sorted { $0.playing && !$1.playing }
    }

    var body: some View {
        let rows = self.rows
        if rows.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { r in
                    SourceRow(row: r, selected: r.id == shown) {
                        store.pickedSource = r.id
                        if r.isMedia { store.request(BarRequest.mediaSelect(r.id)) }
                    }
                }
            }
            PopupDivider()
        }
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? "just now" : "\(m) min ago"
    }
}

private struct SourceRow: View {
    let row: SourceList.Row
    let selected: Bool
    let action: @MainActor () -> Void
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        HStack(spacing: 8) {
            AppIconView(app: AppRef(bundleID: row.id, name: row.name), size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .foregroundStyle(Color(hex: selected || hovering ? t.accent : t.label))
                if let d = row.detail {
                    Text(d).font(.system(size: 10)).foregroundStyle(Color(hex: t.label).opacity(0.6))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            SpectrumBars(source: row.id, playing: row.playing, color: selected ? t.accent : t.icon)
                .frame(width: 44, height: 14)
                .opacity(row.playing ? 1 : 0.3)
        }
        .frame(minHeight: 24)
        .barAction(onHover: { hovering = $0 }, action)
    }
}

/// The current art with the previous track peeking on the left and the
/// next one on the right (when the player shares its queue). Drag left for
/// the next track, right for the previous one; click to play or pause.
private struct ArtCarousel: View {
    let source: MediaSource
    let track: MediaTrack
    let tint: String
    @Environment(BarStore.self) private var store
    @State private var drag: CGFloat = 0
    /// Set while a swipe waits for the player to change tracks.
    @State private var swiped: CGFloat?

    static let size: CGFloat = 200
    static let side: CGFloat = 132
    static let threshold: CGFloat = 60

    var body: some View {
        let x = swiped ?? drag
        let progress = min(abs(x) / Self.side, 1)
        ZStack {
            neighbor(source.previous?.first, symbol: "backward.fill", at: -1, x: x)
            neighbor(source.upNext?.first, symbol: "forward.fill", at: 1, x: x)
            ArtView(path: track.artworkPath, key: track.key, tint: tint, size: Self.size) {
                store.request(BarRequest.mediaToggle)
            }
            .offset(x: x)
            .scaleEffect(1 - 0.18 * progress)
            .rotation3DEffect(.degrees(Double(-x / Self.side) * 35), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .zIndex(1)
        }
        .frame(height: Self.size + 20)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { g in
                    guard swiped == nil else { return }
                    drag = g.translation.width
                }
                .onEnded { g in
                    let dx = g.predictedEndTranslation.width
                    if dx < -Self.threshold {
                        commit(to: -Self.side, BarRequest.mediaNext)
                    } else if dx > Self.threshold {
                        commit(to: Self.side, BarRequest.mediaPreviousTrack)
                    } else {
                        withAnimation(.spring(duration: 0.35)) { drag = 0 }
                    }
                }
        )
        .onChange(of: track.key) {
            // The new track arrived: show it centered.
            swiped = nil
            drag = 0
        }
    }

    private func commit(to x: CGFloat, _ request: String) {
        withAnimation(.spring(duration: 0.3)) { swiped = x }
        drag = 0
        store.request(request)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if swiped == x { withAnimation(.spring(duration: 0.35)) { swiped = nil } }
        }
    }

    /// A neighbor card: the track's art when known, else an empty tile
    /// that only shows while dragging toward it.
    @ViewBuilder
    private func neighbor(_ card: TrackCard?, symbol: String, at slot: CGFloat, x: CGFloat) -> some View {
        let toward = slot < 0 ? max(x, 0) : max(-x, 0)
        let progress = min(toward / Self.side, 1)
        let color = card?.artColor ?? tint
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: color).opacity(0.22))
            if let path = card?.artworkPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Color(hex: color))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            if let card, progress > 0.4 {
                Text(card.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .scaleEffect(0.82 + 0.18 * progress)
        .rotation3DEffect(.degrees(Double(slot) * -35 * (1 - progress)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .offset(x: slot * Self.side + x)
        .opacity(card == nil ? Double(progress) : 0.55 + 0.45 * progress)
    }
}

/// Album art that crossfades between tracks and tilts toward the pointer.
private struct ArtView: View {
    let path: String?
    let key: String
    let tint: String
    var size: CGFloat = 220
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color(hex: tint).opacity(0.45), radius: 18, y: 6)
        .rotation3DEffect(.degrees(Double(tilt.height) * 10), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(Double(-tilt.width) * 10), axis: (x: 0, y: 1, z: 0))
        .animation(.easeOut(duration: 0.2), value: tilt)
        .animation(.easeInOut(duration: 0.4), value: key)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): tilt = CGSize(width: (p.x - size / 2) / (size / 2), height: (p.y - size / 2) / (size / 2))
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
                    BarSlider(value: pos / duration, tint: tint) { v in
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
