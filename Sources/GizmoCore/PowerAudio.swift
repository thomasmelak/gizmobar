import Foundation

/// Battery and power state, from AppleSmartBattery plus pmset/powerd.
public struct BatteryStatus: Sendable, Equatable, Codable {
    public var percent: Int
    /// On the charger.
    public var external: Bool
    public var charging: Bool
    public var full: Bool
    public var lowPower: Bool
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    /// Battery charge (+) or discharge (−) rate in mW.
    public var rateMilliwatts: Int
    /// What the whole Mac draws (SystemLoad), mW. Only trusted on the charger.
    public var loadMilliwatts: Int?
    /// macOS's "Maximum Capacity", %.
    public var health: Int?
    public var cycles: Int?
    public var temperature: Double?
    public var chargerWatts: Int?
    public var chargeLimit: Int?
    /// pmset disablesleep: stays awake with the lid closed.
    public var noSleep: Bool?

    public init(percent: Int, external: Bool = false, charging: Bool = false, full: Bool = false, lowPower: Bool = false,
                minutesToEmpty: Int? = nil, minutesToFull: Int? = nil, rateMilliwatts: Int = 0, loadMilliwatts: Int? = nil,
                health: Int? = nil, cycles: Int? = nil, temperature: Double? = nil, chargerWatts: Int? = nil,
                chargeLimit: Int? = nil, noSleep: Bool? = nil)
    {
        self.percent = percent
        self.external = external
        self.charging = charging
        self.full = full
        self.lowPower = lowPower
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.rateMilliwatts = rateMilliwatts
        self.loadMilliwatts = loadMilliwatts
        self.health = health
        self.cycles = cycles
        self.temperature = temperature
        self.chargerWatts = chargerWatts
        self.chargeLimit = chargeLimit
        self.noSleep = noSleep
    }

    public var stateLabel: String {
        if !external { return "On battery" }
        if charging { return "Charging" }
        return full ? "Charged" : "Not charging"
    }

    public var timeLabel: String {
        let (minutes, suffix): (Int?, String) = !external ? (minutesToEmpty, "left") : (charging ? (minutesToFull, "to full") : (nil, ""))
        guard let minutes else { return "-" }
        if minutes >= 65535 { return "estimating" }
        return String(format: "%d:%02d %@", minutes / 60, minutes % 60, suffix)
    }

    /// On battery the Mac's draw is the battery's discharge rate.
    public var drawMilliwatts: Int {
        if external, let load = loadMilliwatts, load > 0 { return load }
        return abs(rateMilliwatts)
    }

    public var drawLabel: String { Self.watts(drawMilliwatts) }
    public var rateLabel: String { (rateMilliwatts > 0 ? "+" : "") + Self.watts(rateMilliwatts) }

    public static func watts(_ mw: Int) -> String { String(format: "%.1f W", Double(mw) / 1000) }

    public enum Tone: Sendable { case charging, low, saver, normal }

    /// The charger wins, then a low charge, then Low Power Mode.
    public var tone: Tone {
        if external { return .charging }
        if percent <= 20 { return .low }
        if lowPower { return .saver }
        return .normal
    }

    /// SF Symbol for the bar.
    public var symbol: String {
        if external { return "battery.100percent.bolt" }
        switch percent {
        case 90...: return "battery.100percent"
        case 60..<90: return "battery.75percent"
        case 30..<60: return "battery.50percent"
        case 10..<30: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

public struct AudioDevice: Sendable, Equatable, Codable, Identifiable {
    public var id: UInt32
    public var name: String
    public var isCurrent: Bool

    public init(id: UInt32, name: String, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
    }

    public enum Kind: Sendable { case headphones, display, speaker }

    public var kind: Kind {
        let n = name.lowercased()
        if ["headphone", "airpods", "buds", "beats"].contains(where: n.contains) { return .headphones }
        if ["hdmi", "display", "dell", "lg"].contains(where: n.contains) { return .display }
        return .speaker
    }
}

public struct AudioStatus: Sendable, Equatable, Codable {
    /// 0...100
    public var volume: Int
    public var muted: Bool
    public var devices: [AudioDevice]

    public init(volume: Int, muted: Bool, devices: [AudioDevice] = []) {
        self.volume = volume
        self.muted = muted
        self.devices = devices
    }

    /// Same steps as volume.sh.
    public var symbol: String {
        if muted || volume == 0 { return "speaker.slash" }
        if volume >= 60 { return "speaker.wave.3" }
        if volume >= 30 { return "speaker.wave.2" }
        return "speaker.wave.1"
    }
}
