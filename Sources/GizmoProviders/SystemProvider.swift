#if canImport(Darwin)
import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import GizmoCore

/// CPU, GPU, temperature, RAM, swap, disk and lid angle, read in-process
/// every 2 s (system.sh ran ps, ioreg, vm_stat, sysctl, df and two helper
/// binaries for the same thing).
public actor SystemProvider: Provider {
    public nonisolated let id = "system"
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var lastBusy: UInt64 = 0
    private var lastTotal: UInt64 = 0
    private let temperature = TemperatureSensor()
    private let lid = LidSensor()

    public init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    public func start(bus: EventBus) async {
        task?.cancel()
        let interval = self.interval
        task = Task {
            while !Task.isCancelled {
                let stats = self.sample()
                await bus.publish(topic: Topic.systemStats, payload: JSONValue(encoding: stats))
                try? await Task.sleep(for: interval, tolerance: .milliseconds(250))
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
    }

    func sample() -> SystemStats {
        let mem = Self.memory()
        let swap = Self.swap()
        let disk = Self.disk()
        return SystemStats(
            cpu: cpu(),
            gpu: Self.gpu(),
            temperature: temperature.hottestCPU(),
            ramUsed: mem.used, ramTotal: mem.total,
            swapUsed: swap.used, swapTotal: swap.total,
            diskUsed: disk.used, diskTotal: disk.total,
            lidAngle: lid.angle()
        )
    }

    /// Busy share of all cores since the last sample.
    private func cpu() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            let used = tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + tick(CPU_STATE_NICE)
            busy += used
            total += used + tick(CPU_STATE_IDLE)
        }
        defer { lastBusy = busy; lastTotal = total }
        guard lastTotal > 0, total > lastTotal, busy >= lastBusy else { return 0 }
        return min(1, Double(busy - lastBusy) / Double(total - lastTotal))
    }

    /// Like Activity Monitor: active + wired + compressed pages.
    static func memory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard ok == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, total)
    }

    static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// Like Finder: the data volume's size minus what's available.
    static func disk() -> (used: UInt64, total: UInt64) {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 || statfs("/", &fs) == 0 else { return (0, 0) }
        let block = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * block
        let available = UInt64(fs.f_bavail) * block
        return (total - min(total, available), total)
    }

    /// The accelerator's own "Device Utilization %".
    static func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), let stats = raw as? [String: Any]
            else { continue }
            if let u = stats["Device Utilization %"] as? Int { return Double(u) / 100 }
        }
        return nil
    }
}

// MARK: - Temperature (moved in from helpers/cpu_temp.swift)

// IOHIDEventSystemClient's event calls are private API, declared by hand.
private typealias IOHIDEventRef = OpaquePointer
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClient, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClient, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> IOHIDEventRef?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

/// The hottest CPU die sensor from the chip's HID temperature sensors; no
/// admin rights needed. The client and service list are created once.
final class TemperatureSensor {
    private let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature
    private var services: [IOHIDServiceClient] = []

    init() {
        let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        // CPU die sensors are "PMU tdie<n>"; fall back to every PMU sensor.
        func name(_ s: IOHIDServiceClient) -> String {
            (IOHIDServiceClientCopyProperty(s, "Product" as CFString) as? String) ?? ""
        }
        let dies = all.filter { name($0).hasPrefix("PMU tdie") }
        services = dies.isEmpty ? all.filter { name($0).hasPrefix("PMU") } : dies
    }

    func hottestCPU() -> Double? {
        var hottest: Double?
        for service in services {
            guard let event = IOHIDServiceClientCopyEvent(service, temperatureEvent, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(temperatureEvent << 16))
            if value > 0, value < 150 { hottest = max(hottest ?? 0, value) }
        }
        return hottest
    }
}

// MARK: - Lid angle (moved in from helpers/lid_angle.swift)

/// The MacBook lid angle sensor (Apple HID 05AC:8104), feature report 1.
/// nil on Macs without one.
final class LidSensor {
    private var device: IOHIDDevice?
    private var triedOpen = false

    func angle() -> Int? {
        if !triedOpen { open() }
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess else { return nil }
        return Int(report[1]) | Int(report[2]) << 8
    }

    private func open() {
        triedOpen = true
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A,
        ] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let d = devices.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return }
        device = d
    }
}
#endif
