import SwiftUI
import GizmoCore

/// Upload over download in one pill. Click for the Connectivity popover:
/// Wi-Fi and Bluetooth switches, connection, signal, IP, router and the
/// connected Bluetooth devices with their battery levels.
struct NetworkWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        let n = store.snapshot.network
        let offline = n.interface == nil
        Pill(focused: showing, hovered: hovering) {
            VStack(alignment: .trailing, spacing: -1) {
                line("arrow.up", offline ? "offline" : Units.speed(n.upload), t.netUp)
                line("arrow.down", offline ? "offline" : Units.speed(n.download), t.netDown)
            }
        }
        .barAction(onHover: { hovering = $0 }) { showing.toggle() }
        .barPopover(id: "network", isPresented: $showing) { ConnectivityPopover() }
        .onChange(of: showing) { _, shown in
            if shown { store.request(BarRequest.refreshConnectivity) }
        }
    }

    private func line(_ icon: String, _ text: String, _ color: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.custom(store.theme.font, size: 10).monospacedDigit())
                .frame(width: 66, alignment: .trailing)
        }
        .foregroundStyle(Color(hex: color))
    }
}

struct ConnectivityPopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        let c = store.snapshot.connectivity
        VStack(alignment: .leading, spacing: 6) {
            PopupHeader(icon: "wifi", title: "Connectivity", action: { openSettings("com.apple.Network-Settings.extension") })

            PopupRow(icon: "wifi", text: "Wi-Fi") {
                BarSwitch(isOn: c?.wifiPower ?? false) { store.request(BarRequest.toggleWiFi) }
            }
            if let c {
                let active = c.kind == .ethernet || c.signal != nil
                PopupRow(icon: connectionIcon(c), text: c.connectionLabel,
                         color: active ? t.accent : (c.wifiPower ? nil : t.workspaceIcon),
                         iconColor: active ? t.accent : t.workspaceIcon,
                         action: { openSettings("com.apple.Network-Settings.extension") })
                if let q = c.signal {
                    PopupRow(icon: "cellularbars", text: "Signal  \(q.rawValue) · \(c.rssi) dBm",
                             action: { openSettings("com.apple.Network-Settings.extension") })
                }
                PopupRow(icon: "network", text: "IP      \(c.ip ?? "none")",
                         action: { openSettings("com.apple.Network-Settings.extension") })
                PopupRow(icon: "wifi.router", text: "Router  \(c.router ?? "none")",
                         action: { openSettings("com.apple.Network-Settings.extension") })
            } else {
                PopupRow(icon: "ellipsis", text: "Loading…", color: t.workspaceIcon)
            }

            PopupDivider()

            PopupRow(icon: "antenna.radiowaves.left.and.right", text: "Bluetooth") {
                BarSwitch(isOn: c?.bluetoothPower ?? false) { store.request(BarRequest.toggleBluetooth) }
            }
            if let c {
                if c.devices.isEmpty {
                    PopupRow(icon: "antenna.radiowaves.left.and.right", text: c.bluetoothPower ? "No devices connected" : "Off",
                             color: t.workspaceIcon, action: { openSettings("com.apple.BluetoothSettings") })
                } else {
                    ForEach(c.devices.prefix(4)) { d in
                        PopupRow(icon: deviceIcon(d.kind), text: d.battery.map { "\(d.name)  \($0)" } ?? d.name,
                                 action: { openSettings("com.apple.BluetoothSettings") })
                    }
                }
            }
        }
        .frame(minWidth: 270)
    }

    private func openSettings(_ pane: String) {
        PopoverController.shared.close()
        SystemSettings.open(pane)
    }

    private func connectionIcon(_ c: Connectivity) -> String {
        if c.kind == .ethernet { return "cable.connector" }
        switch c.signal {
        case .excellent, .good: return "wifi"
        case .fair, .weak: return "wifi.exclamationmark"
        case nil: return "wifi.slash"
        }
    }

    private func deviceIcon(_ k: BluetoothDevice.Kind) -> String {
        switch k {
        case .headphones: return "headphones"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .speaker: return "hifispeaker"
        case .phone: return "iphone"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}
