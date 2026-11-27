import SwiftUI
import GizmoCore

/// Speaker icon and volume %. Click for the Sound popover: mute in the
/// header, a volume slider and the output devices (current one in accent).
struct VolumeWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if let a = store.snapshot.audio {
            let t = store.theme
            Pill(focused: showing, hovered: hovering) {
                HStack(spacing: 6) {
                    Image(systemName: a.symbol)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(Color(hex: t.icon))
                        .frame(width: 18)
                    Text("\(a.volume)%")
                        .font(.custom(t.font, size: t.fontSize).monospacedDigit())
                        .foregroundStyle(Color(hex: t.label))
                        .frame(minWidth: 34, alignment: .leading)
                }
            }
            .barAction(onHover: { hovering = $0 }) { showing.toggle() }
            .barPopover(id: "volume", isPresented: $showing) { SoundPopover() }
        }
    }
}

struct SoundPopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        if let a = store.snapshot.audio {
            VStack(alignment: .leading, spacing: 8) {
                PopupHeader(icon: "speaker.wave.3", title: "Sound", action: {
                    PopoverController.shared.close()
                    SystemSettings.open("com.apple.Sound-Settings.extension")
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.slash").font(.system(size: 12, weight: .light))
                        BarSwitch(isOn: a.muted) { store.request(BarRequest.toggleMute) }
                    }
                }
                HStack(spacing: 0) {
                    Image(systemName: a.symbol)
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Color(hex: t.icon))
                        .frame(width: 36, alignment: .leading)
                    BarSlider(value: Double(a.volume) / 100, tint: a.muted ? t.icon : t.accent) { v in
                        store.request(BarRequest.setVolume(v))
                    }
                    .frame(width: 176)
                    Text("\(a.volume)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                PopupDivider()
                ForEach(a.devices.prefix(5)) { d in
                    PopupRow(icon: icon(d.kind), text: d.name,
                             color: d.isCurrent ? t.accent : nil, iconColor: d.isCurrent ? t.accent : t.label,
                             action: { store.request(BarRequest.selectOutput(d.id)) })
                }
            }
            .frame(minWidth: 270)
        }
    }

    private func icon(_ k: AudioDevice.Kind) -> String {
        switch k {
        case .headphones: return "headphones"
        case .display: return "display"
        case .speaker: return "hifispeaker"
        }
    }
}

/// A slider in the theme colors. Click or drag; reports while dragging
/// (throttled to ~20 Hz) and once at the end.
struct BarSlider: View {
    let value: Double
    var tint: String
    /// Fill colors left to right; `tint` alone when nil.
    var gradient: [String]? = nil
    /// Send only when released (seeking), instead of while dragging (volume).
    var commitOnRelease = false
    let onChange: @MainActor (Double) -> Void
    @Environment(BarStore.self) private var store
    @State private var dragValue: Double?
    /// The released value, shown until `value` catches up with it, so the
    /// knob doesn't jump back while the change is applied.
    @State private var held: Double?
    @State private var lastSent = Date.distantPast

    var body: some View {
        let t = store.theme
        let shown = dragValue ?? held ?? value
        let colors = (gradient?.isEmpty == false ? gradient! : [tint]).map { Color(hex: $0) }
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: t.itemBorder)).frame(height: 6)
                Capsule().fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 6)
                    .mask(alignment: .leading) { Capsule().frame(width: max(6, w * shown), height: 6) }
                Circle().fill(Color(hex: t.label)).frame(width: 12, height: 12)
                    .offset(x: min(max(0, w * shown - 6), w - 12))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(PointerArea(pointer: true, onHover: nil))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let v = min(max(g.location.x / w, 0), 1)
                        dragValue = v
                        if !commitOnRelease, Date().timeIntervalSince(lastSent) > 0.05 {
                            lastSent = Date()
                            onChange(v)
                        }
                    }
                    .onEnded { g in
                        let v = min(max(g.location.x / w, 0), 1)
                        onChange(v)
                        hold(v)
                        dragValue = nil
                    }
            )
        }
        .onChange(of: value) { _, new in
            if let h = held, abs(new - h) < 0.02 { held = nil }
        }
        .frame(height: 20)
    }

    /// Keeps `v` on screen until the source reports it, or 2.5 s at most.
    private func hold(_ v: Double) {
        held = v
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if held == v { held = nil }
        }
    }
}
