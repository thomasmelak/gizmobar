#if canImport(Darwin)
import Foundation
import IOKit
import IOKit.ps
import GizmoCore

/// Battery state from AppleSmartBattery. Push: power-source notifications
/// and Low Power Mode changes. The slow details (health, charge limit, No
/// Sleep) are read when the popover opens and every 5 s while it's open.
public actor BatteryProvider: Provider {
    public nonisolated let id = "battery"
    private var bus: EventBus?
    private var source: CFRunLoopSource?
    private var lowPowerToken: NSObjectProtocol?
    private var detailTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var details = Details()
    private var healthReadAt: Date?

    private struct Details {
        var health: Int?
        var chargeLimit: Int?
        var noSleep: Bool?
    }

    public init() {}

    public func start(bus: EventBus) async {
        self.bus = bus
        guard Self.readBattery() != nil else { return } // desktop Mac
        await publish()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let provider = Unmanaged<BatteryProviderBox>.fromOpaque(context).takeUnretainedValue().provider
            Task { await provider?.publish() }
        }
        let box = BatteryProviderBox(self)
        if let src = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passRetained(box).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        lowPowerToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in Task { await self?.publish() } }
        // Percent and time don't always notify; a slow safety net.
        fallbackTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
                await self.publish()
            }
        }
    }

    public func stop() async {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        if let lowPowerToken { NotificationCenter.default.removeObserver(lowPowerToken) }
        detailTask?.cancel()
        fallbackTask?.cancel()
    }

    /// Popover open: refresh details now and every 5 s until `setDetailed(false)`.
    public func setDetailed(_ on: Bool) {
        detailTask?.cancel()
        guard on else { return }
        detailTask = Task {
            while !Task.isCancelled {
                await self.refreshDetails()
                await self.publish()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func publish() async {
        guard var status = Self.readBattery() else { return }
        status.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        status.health = details.health
        status.chargeLimit = details.chargeLimit
        status.noSleep = details.noSleep
        await bus?.publish(topic: Topic.battery, payload: JSONValue(encoding: status))
    }

    private func refreshDetails() async {
        details.noSleep = await Self.sleepDisabled()
        details.chargeLimit = Self.chargeLimit()
        if healthReadAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            details.health = await Self.maximumCapacity()
            healthReadAt = Date()
        }
    }

    // MARK: Actions

    public func toggleLowPower() async {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        await Self.pmset("lowpowermode", on ? 0 : 1, prompt: "Turn Low Power Mode \(on ? "off" : "on").")
        await publish()
    }

    public func toggleNoSleep() async {
        let on = await Self.sleepDisabled() ?? false
        await Self.pmset("disablesleep", on ? 0 : 1, prompt: "Turn No Sleep \(on ? "off" : "on") (the Mac stays awake with the lid closed).")
        details.noSleep = await Self.sleepDisabled()
        await publish()
    }

    /// macOS only lets its own apps set the limit; this runs the user's
    /// "Set Charge Limit" shortcut (Set Battery Charge Limit action).
    public func setChargeLimit() async {
        _ = try? await Command.run("/usr/bin/shortcuts", ["run", "Set Charge Limit"])
        details.chargeLimit = Self.chargeLimit()
        await publish()
    }

    /// Uses the passwordless sudoers rule if present, else macOS's own
    /// admin prompt; cancelling changes nothing.
    static func pmset(_ key: String, _ value: Int, prompt: String) async {
        if (try? await Command.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", key, "\(value)"])) != nil { return }
        let script = "do shell script \"/usr/bin/pmset -a \(key) \(value)\" with prompt \"\(prompt)\" with administrator privileges"
        _ = try? await Command.run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: Reading

    static func readBattery() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return nil }
        func int(_ key: String) -> Int? { (dict[key] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) } }
        func bool(_ key: String) -> Bool { (dict[key] as? Bool) ?? false }

        let voltage = int("Voltage") ?? 0
        let amperage = int("Amperage") ?? 0 // signed; negative while discharging
        let telemetry = dict["PowerTelemetryData"] as? [String: Any]
        let adapter = dict["AdapterDetails"] as? [String: Any]
        let load = (telemetry?["SystemLoad"] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        return BatteryStatus(
            percent: int("CurrentCapacity") ?? 0,
            external: bool("ExternalConnected"),
            charging: bool("IsCharging"),
            full: bool("FullyCharged"),
            minutesToEmpty: int("AvgTimeToEmpty"),
            minutesToFull: int("AvgTimeToFull"),
            rateMilliwatts: voltage * amperage / 1000,
            loadMilliwatts: load,
            cycles: int("CycleCount"),
            temperature: int("Temperature").map { Double($0) / 100 },
            chargerWatts: (adapter?["Watts"] as? NSNumber)?.intValue
        )
    }

    static func sleepDisabled() async -> Bool? {
        guard let data = try? await Command.run("/usr/bin/pmset", ["-g"]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(separator: " ").last == "1"
        }
        return false
    }

    /// "Maximum Capacity" as System Settings shows it (not in ioreg).
    static func maximumCapacity() async -> Int? {
        guard let data = try? await Command.run("/usr/sbin/system_profiler", ["SPPowerDataType"]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("Maximum Capacity") {
            return Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "") ?? "")
        }
        return nil
    }

    /// powerd keeps the limit as a "soclimit" in an archived policies array;
    /// readable without admin rights. No policy means no limit (100%).
    static func chargeLimit() -> Int? {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
        guard let prefs = NSDictionary(contentsOf: url) as? [String: Any] else { return 100 }
        guard let data = prefs["policies"] as? Data,
              let policies = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return 100 }
        return findSocLimit(policies) ?? 100
    }

    private static func findSocLimit(_ value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            if let n = dict["soclimit"] as? NSNumber { return n.intValue }
            for v in dict.values { if let found = findSocLimit(v) { return found } }
        } else if let array = value as? [Any] {
            for v in array { if let found = findSocLimit(v) { return found } }
        }
        return nil
    }
}

/// Lets the C power-source callback reach the actor.
private final class BatteryProviderBox: @unchecked Sendable {
    weak var provider: BatteryProvider?
    init(_ provider: BatteryProvider) { self.provider = provider }
}
#endif
