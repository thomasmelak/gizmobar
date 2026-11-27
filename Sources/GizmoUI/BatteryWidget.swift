import SwiftUI
import GizmoCore

/// Battery icon and %, colored by state: charging, low, Low Power Mode.
/// Click for the Battery popover with Low Power Mode in the header and a
/// No Sleep switch, like the SketchyBar one.
struct BatteryWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if let b = store.snapshot.battery {
            let t = store.theme
            Pill(focused: showing, hovered: hovering) {
                HStack(spacing: 6) {
                    Image(systemName: b.symbol)
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Color(hex: toneColor(b.tone, t)))
                    Text("\(b.percent)%")
                        .font(.custom(t.font, size: t.fontSize).monospacedDigit())
                        .foregroundStyle(Color(hex: t.label))
                        .frame(minWidth: 34, alignment: .leading)
                }
            }
            .barAction(onHover: { hovering = $0 }) { showing.toggle() }
            .barPopover(id: "battery", isPresented: $showing) { BatteryPopover() }
            .onChange(of: showing) { _, shown in
                store.request(shown ? BarRequest.batteryDetailsOn : BarRequest.batteryDetailsOff)
            }
        }
    }
}

func toneColor(_ tone: BatteryStatus.Tone, _ t: Theme) -> String {
    switch tone {
    case .charging: return t.good
    case .low: return t.bad
    case .saver: return t.warn
    case .normal: return t.icon
    }
}

struct BatteryPopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        if let b = store.snapshot.battery {
            VStack(alignment: .leading, spacing: 6) {
                PopupHeader(icon: "battery.75percent", title: "Battery", action: settings) {
                    HStack(spacing: 6) {
                        Image(systemName: "leaf").font(.system(size: 12, weight: .light))
                        BarSwitch(isOn: b.lowPower) { store.request(BarRequest.toggleLowPower) }
                    }
                }
                PopupRow(icon: b.symbol, text: "State     \(b.stateLabel)", iconColor: toneColor(b.tone, t), action: settings)
                PopupDivider()
                PopupRow(icon: "hourglass", text: "Time      \(b.timeLabel)", action: settings)
                PopupDivider()
                PopupRow(icon: "bolt", text: "Draw      \(b.drawLabel)", action: settings)
                PopupDivider()
                PopupRow(icon: "minus.plus.batteryblock", text: "Battery   \(b.rateLabel)", action: settings)
                PopupDivider()
                PopupRow(icon: "heart.text.square", text: "Health    \(b.health.map { "\($0)%" } ?? "?") · \(b.cycles.map(String.init) ?? "?") cycles",
                         color: (b.health ?? 100) < 80 ? t.bad : nil, action: settings)
                PopupDivider()
                PopupRow(icon: "thermometer.medium", text: "Temp      \(b.temperature.map { "\(Int($0.rounded()))°C" } ?? "?")", action: settings)
                PopupDivider()
                PopupRow(icon: "powerplug", text: "Charger   \(b.external ? "\(b.chargerWatts.map(String.init) ?? "?") W" : "-")", action: settings)
                PopupDivider()
                PopupRow(icon: "battery.75percent", text: "Limit     \(b.chargeLimit.map { "\($0)%" } ?? "?")", action: {
                    PopoverController.shared.close()
                    store.request(BarRequest.setChargeLimit)
                })
                PopupDivider()
                PopupRow(icon: "cup.and.saucer", text: "No Sleep") {
                    BarSwitch(isOn: b.noSleep ?? false) { store.request(BarRequest.toggleNoSleep) }
                }
            }
            .frame(minWidth: 270)
        }
    }

    private func settings() {
        PopoverController.shared.close()
        SystemSettings.open("com.apple.Battery-Settings.extension")
    }
}
