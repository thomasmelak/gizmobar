import Foundation

/// One sample of the system provider. Fractions are 0...1.
public struct SystemStats: Sendable, Equatable, Codable {
    public var cpu: Double
    public var gpu: Double?
    /// Hottest CPU die sensor, °C.
    public var temperature: Double?
    public var ramUsed: UInt64
    public var ramTotal: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var diskUsed: UInt64
    public var diskTotal: UInt64
    /// MacBook lid angle in degrees.
    public var lidAngle: Int?

    public init(cpu: Double, gpu: Double? = nil, temperature: Double? = nil, ramUsed: UInt64 = 0, ramTotal: UInt64 = 0,
                swapUsed: UInt64 = 0, swapTotal: UInt64 = 0, diskUsed: UInt64 = 0, diskTotal: UInt64 = 0, lidAngle: Int? = nil)
    {
        self.cpu = cpu
        self.gpu = gpu
        self.temperature = temperature
        self.ramUsed = ramUsed
        self.ramTotal = ramTotal
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.lidAngle = lidAngle
    }

    public var ramFraction: Double { ramTotal > 0 ? Double(ramUsed) / Double(ramTotal) : 0 }
    public var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
    public var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
    public var swapInUse: Bool { swapUsed > 0 }
    /// Temperature as a chart value: 0–100 °C → 0...1.
    public var temperatureFraction: Double? { temperature.map { min(max($0, 0), 100) / 100 } }
}

/// Network throughput on the default-route interface, bytes per second.
public struct NetworkSpeed: Sendable, Equatable, Codable {
    public var download: Double
    public var upload: Double
    /// nil when offline.
    public var interface: String?

    public init(download: Double, upload: Double, interface: String?) {
        self.download = download
        self.upload = upload
        self.interface = interface
    }

    public static let offline = NetworkSpeed(download: 0, upload: 0, interface: nil)
}

public struct Connectivity: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case wifi, ethernet, none }

    public var kind: Kind
    public var wifiPower: Bool
    /// dBm; 0 when not associated.
    public var rssi: Int
    public var channel: Int?
    /// "2.4 GHz", "5 GHz", "6 GHz".
    public var band: String?
    public var interface: String?
    public var ip: String?
    public var router: String?
    public var bluetoothPower: Bool
    public var devices: [BluetoothDevice]

    public init(kind: Kind = .none, wifiPower: Bool = false, rssi: Int = 0, channel: Int? = nil, band: String? = nil,
                interface: String? = nil, ip: String? = nil, router: String? = nil, bluetoothPower: Bool = false,
                devices: [BluetoothDevice] = [])
    {
        self.kind = kind
        self.wifiPower = wifiPower
        self.rssi = rssi
        self.channel = channel
        self.band = band
        self.interface = interface
        self.ip = ip
        self.router = router
        self.bluetoothPower = bluetoothPower
        self.devices = devices
    }

    public enum SignalQuality: String, Sendable { case excellent = "Excellent", good = "Good", fair = "Fair", weak = "Weak" }

    /// Same thresholds as the SketchyBar connectivity popup.
    public var signal: SignalQuality? {
        guard wifiPower, rssi != 0, band != nil else { return nil }
        if rssi >= -55 { return .excellent }
        if rssi >= -67 { return .good }
        if rssi >= -75 { return .fair }
        return .weak
    }

    /// The connection row: "5 GHz · channel 36", "Ethernet", "Off", "Not connected".
    public var connectionLabel: String {
        if kind == .ethernet { return "Ethernet" }
        if !wifiPower { return "Off" }
        guard rssi != 0, let band else { return "Not connected" }
        return channel.map { "\(band) · channel \($0)" } ?? band
    }
}

public struct BluetoothDevice: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case headphones, mouse, keyboard, speaker, phone, other }

    public var name: String
    public var kind: Kind
    /// "85%", as macOS reports it.
    public var battery: String?

    public var id: String { name }

    public init(name: String, kind: Kind = .other, battery: String? = nil) {
        self.name = name
        self.kind = kind
        self.battery = battery
    }

    /// From system_profiler's "Minor Type".
    public static func kind(minorType: String?) -> Kind {
        let t = (minorType ?? "").lowercased()
        if t.contains("headset") || t.contains("headphone") { return .headphones }
        if t.contains("mouse") || t.contains("trackpad") { return .mouse }
        if t.contains("keyboard") { return .keyboard }
        if t.contains("speaker") || t.contains("stereo") { return .speaker }
        if t.contains("phone") { return .phone }
        return .other
    }
}

/// A fixed-size chart history. Like the SketchyBar charts, a value is only
/// pushed when it changed, so a steady reading doesn't flatten the line;
/// the first value fills the whole history instead of starting from zero.
public struct History: Sendable, Equatable {
    public private(set) var values: [Double]
    public let capacity: Int

    public init(capacity: Int = 56) {
        self.capacity = capacity
        self.values = []
    }

    public mutating func push(_ value: Double) {
        if values.isEmpty {
            values = Array(repeating: value, count: capacity)
            return
        }
        guard value != values.last else { return }
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

public enum Units {
    /// `8.0 KB/s`, `1.2 MB/s`, `512 B/s`, matching network.sh.
    public static func speed(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.1f KB/s", b / 1_000) }
        return String(format: "%.0f B/s", b)
    }

    /// `12.3 / 16 GB` (binary GB, like Activity Monitor).
    public static func usedOfTotal(_ used: UInt64, _ total: UInt64, usedDecimals: Int = 1) -> String {
        let gb = 1_073_741_824.0
        return String(format: "%.\(usedDecimals)f / %.0f GB", Double(used) / gb, Double(total) / gb)
    }

    /// `512 MB` or `1.5 GB`.
    public static func size(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

extension JSONValue {
    /// Encodes any Codable value as a bus payload.
    public init<T: Encodable>(encoding value: T) {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        self = (try? JSONValue(parsing: data)) ?? .null
    }

    /// Decodes a bus payload back into a Codable value.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
