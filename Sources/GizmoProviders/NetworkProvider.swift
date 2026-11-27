#if canImport(Darwin)
import CoreWLAN
import Darwin
import Foundation
import Network
import SystemConfiguration
import GizmoCore

// IOBluetooth's power calls (what blueutil uses), declared by hand.
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
private func IOBluetoothPreferenceGetControllerPowerState() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
private func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

/// Network speed on the default-route interface (every 2 s, from the
/// kernel's 64-bit interface counters) and, on demand, the connectivity
/// details for the popover: Wi-Fi, IP, router and Bluetooth devices.
public actor NetworkProvider: Provider {
    public nonisolated let id = "network"
    private let interval: Duration
    private var bus: EventBus?
    private var task: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var last: (time: ContinuousClock.Instant, rx: UInt64, tx: UInt64, interface: String)?

    public init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    public func start(bus: EventBus) async {
        self.bus = bus
        task?.cancel()
        let interval = self.interval
        task = Task {
            while !Task.isCancelled {
                await bus.publish(topic: Topic.networkSpeed, payload: JSONValue(encoding: self.sampleSpeed()))
                try? await Task.sleep(for: interval, tolerance: .milliseconds(250))
            }
        }
        // A route change (Wi-Fi ↔ Ethernet, going offline) restarts the speed
        // baseline and refreshes the connectivity details.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.pathChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "gizmobar.network.path"))
        self.monitor = monitor
    }

    public func stop() async {
        task?.cancel()
        monitor?.cancel()
    }

    private func pathChanged() async {
        last = nil
        await refreshConnectivity(includeBluetooth: false)
    }

    // MARK: Speed

    func sampleSpeed() -> NetworkSpeed {
        guard let interface = Self.primaryInterface(), let counters = Self.counters(for: interface) else {
            last = nil
            return .offline
        }
        let now = ContinuousClock.now
        defer { last = (now, counters.rx, counters.tx, interface) }
        guard let last, last.interface == interface, counters.rx >= last.rx, counters.tx >= last.tx else {
            return NetworkSpeed(download: 0, upload: 0, interface: interface)
        }
        let seconds = max(0.5, Double((now - last.time).components.seconds) + Double((now - last.time).components.attoseconds) / 1e18)
        return NetworkSpeed(
            download: Double(counters.rx - last.rx) / seconds,
            upload: Double(counters.tx - last.tx) / seconds,
            interface: interface
        )
    }

    /// 64-bit byte counters from the routing socket (getifaddrs' are 32-bit and wrap).
    static func counters(for interface: String) -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0, found = false
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil, String(cString: name) == interface {
                        rx = h2.ifm_data.ifi_ibytes
                        tx = h2.ifm_data.ifi_obytes
                        found = true
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return found ? (rx, tx) : nil
    }

    // MARK: Connectivity

    /// Wi-Fi, IP, router and (optionally) Bluetooth, published as
    /// `network.connectivity`. Called when the popover opens.
    public func refreshConnectivity(includeBluetooth: Bool = true) async {
        var c = Connectivity()
        let wifi = CWWiFiClient.shared().interface()
        let primary = Self.primaryInterface()
        c.interface = primary
        c.wifiPower = wifi?.powerOn() ?? false
        c.rssi = wifi?.rssiValue() ?? 0
        if let channel = wifi?.wlanChannel() {
            c.channel = channel.channelNumber
            switch channel.channelBand {
            case .band2GHz: c.band = "2.4 GHz"
            case .band5GHz: c.band = "5 GHz"
            case .band6GHz: c.band = "6 GHz"
            default: c.band = nil
            }
        }
        if let primary {
            c.kind = primary == wifi?.interfaceName ? .wifi : .ethernet
            c.ip = Self.ipv4(for: primary)
        }
        c.router = Self.globalIPv4()?["Router"] as? String
        c.bluetoothPower = IOBluetoothPreferenceGetControllerPowerState() != 0
        if includeBluetooth {
            c.devices = c.bluetoothPower ? await Self.bluetoothDevices() : []
        } else if let previous = lastConnectivity {
            c.devices = previous.devices
        }
        lastConnectivity = c
        await bus?.publish(topic: Topic.networkConnectivity, payload: JSONValue(encoding: c))
    }

    private var lastConnectivity: Connectivity?

    public func toggleWiFi() async {
        guard let wifi = CWWiFiClient.shared().interface() else { return }
        try? wifi.setPower(!wifi.powerOn())
        await refreshConnectivity(includeBluetooth: false)
    }

    public func toggleBluetooth() async {
        let on = IOBluetoothPreferenceGetControllerPowerState() != 0
        IOBluetoothPreferenceSetControllerPowerState(on ? 0 : 1)
        try? await Task.sleep(for: .milliseconds(600))
        await refreshConnectivity(includeBluetooth: true)
    }

    // MARK: SystemConfiguration

    static func globalIPv4() -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "gizmobar" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    }

    static func primaryInterface() -> String? {
        globalIPv4()?["PrimaryInterface"] as? String
    }

    static func ipv4(for interface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "gizmobar" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return (dict["Addresses"] as? [String])?.first
    }

    // MARK: Bluetooth

    /// Connected devices with battery levels, from system_profiler (the only
    /// place macOS reports battery levels). Runs only when the popover opens.
    static func bluetoothDevices() async -> [BluetoothDevice] {
        guard let data = try? await Command.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let root = try? JSONValue(parsing: data),
              let controllers = root["SPBluetoothDataType"]?.array
        else { return [] }
        var devices: [BluetoothDevice] = []
        for controller in controllers {
            for entry in controller["device_connected"]?.array ?? [] {
                guard case .object(let named) = entry else { continue }
                for (name, info) in named {
                    let battery = info["device_batteryLevelMain"]?.string
                        ?? info["device_batteryLevelLeft"]?.string
                        ?? info["device_batteryLevelRight"]?.string
                    devices.append(BluetoothDevice(
                        name: name,
                        kind: BluetoothDevice.kind(minorType: info["device_minorType"]?.string),
                        battery: battery
                    ))
                }
            }
        }
        return devices
    }
}
#endif
