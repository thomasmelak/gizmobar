import SwiftUI
import GizmoCore

/// Sun icon and the main display's brightness. Click for the Displays
/// popover: a section per display (brightness, plus contrast over DDC) and
/// Night Shift with its warmth.
struct BrightnessWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if let main = store.snapshot.displays?.main {
            let t = store.theme
            Pill(focused: showing, hovered: hovering) {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(Color(hex: t.icon))
                        .frame(width: 18)
                    Text(main.brightness.map { "\($0)%" } ?? "--")
                        .font(.custom(t.font, size: t.fontSize).monospacedDigit())
                        .foregroundStyle(Color(hex: t.label))
                        .frame(minWidth: 34, alignment: .leading)
                }
            }
            .barAction(onHover: { hovering = $0 }) { showing.toggle() }
            .barPopover(id: "displays", isPresented: $showing) { DisplaysPopover() }
            .onChange(of: showing) { _, open in
                if open { store.request(BarRequest.refreshDisplays) }
            }
        }
    }
}

struct DisplaysPopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        if let s = store.snapshot.displays {
            VStack(alignment: .leading, spacing: 8) {
                PopupHeader(icon: "display", title: "Displays", action: {
                    PopoverController.shared.close()
                    SystemSettings.open("com.apple.Displays-Settings.extension")
                })
                ForEach(s.displays.prefix(3)) { d in
                    PopupDivider()
                    PopupRow(icon: d.isBuiltIn ? "laptopcomputer" : "display", text: d.name,
                             color: d.isMain ? t.accent : nil)
                    LevelRow(icon: "sun.max", value: d.brightness) { v in
                        store.request(BarRequest.setBrightness(display: d.id, v))
                    }
                    if d.control == .ddc {
                        LevelRow(icon: "circle.lefthalf.filled", value: d.contrast) { v in
                            store.request(BarRequest.setContrast(display: d.id, v))
                        }
                    }
                }
                if let on = s.nightShift {
                    PopupDivider()
                    PopupRow(icon: "moon", text: "Night Shift") {
                        BarSwitch(isOn: on) { store.request(BarRequest.toggleNightShift) }
                    }
                    if on {
                        LevelRow(icon: "thermometer.sun", value: s.warmth) { v in
                            store.request(BarRequest.setWarmth(v))
                        }
                    }
                }
            }
            .frame(minWidth: 270)
        }
    }
}

/// Icon, slider, percent. Grayed out with "--" when the value is unknown
/// (a monitor that didn't answer over DDC).
private struct LevelRow: View {
    let icon: String
    let value: Int?
    let onChange: @MainActor (Int) -> Void
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color(hex: t.icon))
                .frame(width: 36, alignment: .leading)
            BarSlider(value: Double(value ?? 0) / 100, tint: value == nil ? t.icon : t.accent) { v in
                onChange(Int((v * 100).rounded()))
            }
            .frame(width: 176)
            .disabled(value == nil)
            .opacity(value == nil ? 0.5 : 1)
            Text(value.map { "\($0)%" } ?? "--").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
