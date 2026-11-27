import SwiftUI
import GizmoCore

/// A gauge with the CPU % (red while swap is in use). Click for the
/// Performance popover: CPU, GPU, temperature and swap charts, RAM and disk
/// pies, and the lid angle. Rows open Activity Monitor on the matching tab.
struct SystemWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        let s = store.snapshot.system
        Pill(focused: showing, hovered: hovering) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Color(hex: s?.swapInUse == true ? t.bad : t.icon))
                Text(s.map { Units.percent($0.cpu) } ?? "--")
                    .font(.custom(t.font, size: t.fontSize).monospacedDigit())
                    .foregroundStyle(Color(hex: t.label))
                    .frame(minWidth: 34, alignment: .leading)
            }
        }
        .barAction(onHover: { hovering = $0 }) { showing.toggle() }
        .barPopover(id: "system", isPresented: $showing) { SystemPopover() }
    }
}

struct SystemPopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        let snap = store.snapshot
        let s = snap.system
        VStack(alignment: .leading, spacing: 6) {
            PopupHeader(icon: "gauge.with.dots.needle.33percent", title: "Performance")
            PopupRow(icon: "cpu", text: "CPU   " + (s.map { Units.percent($0.cpu) } ?? "?"), action: open(.cpu)) {
                Sparkline(values: snap.cpuHistory.values, color: t.accent)
            }
            PopupDivider()
            PopupRow(icon: "square.stack.3d.up", text: "GPU   " + (s?.gpu.map(Units.percent) ?? "?"), action: open(.cpu)) {
                Sparkline(values: snap.gpuHistory.values, color: t.accent)
            }
            PopupDivider()
            let hot = (s?.temperature ?? 0) >= 85
            PopupRow(icon: "thermometer.medium", text: "Temp  " + (s?.temperature.map { "\(Int($0.rounded()))°C" } ?? "?"),
                     color: hot ? t.bad : nil, action: open(.cpu)) {
                Sparkline(values: snap.temperatureHistory.values, color: t.accent)
            }
            PopupDivider()
            let swapping = s?.swapInUse == true
            PopupRow(icon: "arrow.left.arrow.right", text: "Swap  " + (s.map { Units.size($0.swapUsed) } ?? "?"),
                     color: swapping ? t.bad : nil, iconColor: swapping ? t.bad : nil, action: open(.memory)) {
                Sparkline(values: snap.swapHistory.values, color: t.bad)
            }
            PopupDivider()
            PopupRow(icon: "memorychip", text: "RAM   " + (s.map { Units.usedOfTotal($0.ramUsed, $0.ramTotal) } ?? "?"),
                     action: open(.memory)) {
                Pie(fraction: s?.ramFraction ?? 0)
            }
            PopupDivider()
            PopupRow(icon: "internaldrive", text: "Disk  " + (s.map { Units.usedOfTotal($0.diskUsed, $0.diskTotal, usedDecimals: 0) } ?? "?"),
                     action: open(.disk)) {
                Pie(fraction: s?.diskFraction ?? 0)
            }
            if let lid = s?.lidAngle {
                PopupDivider()
                PopupRow(icon: "laptopcomputer", text: "Lid   \(lid)°")
            }
        }
        .frame(minWidth: 260)
    }

    private func open(_ tab: ActivityMonitor.Tab) -> @MainActor () -> Void {
        { @MainActor in
            PopoverController.shared.close()
            ActivityMonitor.open(tab)
        }
    }
}
