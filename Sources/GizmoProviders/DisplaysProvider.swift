#if canImport(AppKit)
import AppKit
import CoreGraphics
import IOKit
import GizmoCore

/// Brightness and contrast for every display, plus Night Shift.
///
/// - Built-in and Apple displays: DisplayServices (the private framework
///   behind the brightness keys).
/// - External monitors: DDC/CI over IOAVService, in-process (what m1ddc did).
/// - Monitors without DDC: software dimming through the gamma table.
///
/// The bar shows the main display's brightness, polled every 3 s (no event
/// reports changes from the brightness keys). The popover reads every
/// display when it opens.
public actor DisplaysProvider: Provider {
    public nonisolated let id = "displays"
    private var bus: EventBus?
    private var task: Task<Void, Never>?
    private var status = DisplaysStatus(displays: [])
    private var ddc: [CGDirectDisplayID: DDCService] = [:]
    private var softwareLevels: [CGDirectDisplayID: Int] = [:]
    private var screensToken: NSObjectProtocol?

    public init() {}

    public func start(bus: EventBus) async {
        self.bus = bus
        await rescan(full: true)
        screensToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in Task { await self?.rescan(full: true) } }
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3), tolerance: .milliseconds(500))
                await self.pollMain()
            }
        }
    }

    public func stop() async {
        task?.cancel()
        if let screensToken { NotificationCenter.default.removeObserver(screensToken) }
    }

    /// Popover open: read every display (DDC included) and Night Shift.
    public func refresh() async { await rescan(full: true) }

    public func setBrightness(display: UInt32, _ value: Int) async {
        let v = min(max(value, 0), 100)
        guard let i = status.displays.firstIndex(where: { $0.id == display }) else { return }
        switch status.displays[i].control {
        case .builtin: DisplayServices.set(display, Float(v) / 100)
        case .ddc: _ = ddc[display]?.write(DDC.luminance, UInt16(v))
        case .software:
            softwareLevels[display] = v
            SoftwareDimming.apply(display, Double(v) / 100)
        }
        status.displays[i].brightness = v
        await publish()
    }

    public func setContrast(display: UInt32, _ value: Int) async {
        let v = min(max(value, 0), 100)
        guard let i = status.displays.firstIndex(where: { $0.id == display }), let service = ddc[display] else { return }
        _ = service.write(DDC.contrast, UInt16(v))
        status.displays[i].contrast = v
        await publish()
    }

    public func toggleNightShift() async {
        let on = NightShift.status()?.on ?? false
        NightShift.setEnabled(!on)
        readNightShift()
        await publish()
    }

    public func setWarmth(_ value: Int) async {
        NightShift.setStrength(Float(min(max(value, 0), 100)) / 100)
        readNightShift()
        await publish()
    }

    // MARK: Reading

    private func rescan(full: Bool) async {
        let screens = await MainActor.run { Self.screens() }
        let services = DDCService.discover()
        var displays: [DisplayState] = []
        var used = Set<Int>()
        ddc.removeAll()
        for (index, s) in screens.enumerated() {
            var d = DisplayState(id: s.id, name: s.name, isBuiltIn: s.builtIn, isMain: index == 0, control: .software)
            if let level = DisplayServices.get(s.id) {
                d.control = .builtin
                d.brightness = Int((level * 100).rounded())
            } else if let match = DDCService.match(s.id, in: services, excluding: used) {
                used.insert(match)
                let service = services[match]
                ddc[s.id] = service
                d.control = .ddc
                if full || d.isMain {
                    d.brightness = service.read(DDC.luminance).map(Self.percent)
                    d.contrast = full ? service.read(DDC.contrast).map(Self.percent) : nil
                }
                if d.brightness == nil, d.contrast == nil { // no DDC answer: fall back
                    ddc[s.id] = nil
                    d.control = .software
                }
            }
            if d.control == .software { d.brightness = softwareLevels[s.id] ?? 100 }
            displays.append(d)
        }
        status.displays = displays
        readNightShift()
        await publish()
    }

    private func pollMain() async {
        guard let i = status.displays.firstIndex(where: \.isMain) else { return }
        let d = status.displays[i]
        let level: Int?
        switch d.control {
        case .builtin: level = DisplayServices.get(d.id).map { Int(($0 * 100).rounded()) }
        case .ddc: level = ddc[d.id]?.read(DDC.luminance).map(Self.percent)
        case .software: level = d.brightness
        }
        guard let level, level != d.brightness else { return }
        status.displays[i].brightness = level
        await publish()
    }

    private func readNightShift() {
        let ns = NightShift.status()
        status.nightShift = ns?.on
        status.warmth = ns.map { Int(($0.strength * 100).rounded()) }
    }

    private func publish() async {
        await bus?.publish(topic: Topic.displays, payload: JSONValue(encoding: status))
    }

    private static func percent(_ r: (current: UInt16, max: UInt16)) -> Int {
        r.max > 0 ? Int((Double(r.current) / Double(r.max) * 100).rounded()) : Int(r.current)
    }

    /// Screens in NSScreen order, main first.
    @MainActor
    static func screens() -> [(id: CGDirectDisplayID, name: String, builtIn: Bool)] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return (id, screen.localizedName, CGDisplayIsBuiltin(id) != 0)
        }
    }
}

// MARK: - DisplayServices (built-in and Apple displays)

enum DisplayServices {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    nonisolated(unsafe) private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        guard let framework, let p = dlsym(framework, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// 0...1, or nil when the display isn't controlled by DisplayServices.
    static func get(_ id: CGDirectDisplayID) -> Float? {
        guard let get = symbol("DisplayServicesGetBrightness", Get.self) else { return nil }
        var v: Float = 0
        return get(id, &v) == 0 ? v : nil
    }

    static func set(_ id: CGDirectDisplayID, _ value: Float) {
        _ = symbol("DisplayServicesSetBrightness", Set.self)?(id, value)
    }
}

// MARK: - DDC/CI over IOAVService (Apple Silicon)

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ output: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ input: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn

/// One external monitor's I²C channel, found by walking the IORegistry the
/// way MonitorControl and m1ddc do: each framebuffer ("AppleCLCD2" /
/// "IOMobileFramebufferShim") is followed by its "DCPAVServiceProxy".
final class DDCService: @unchecked Sendable {
    let service: CFTypeRef
    let productID: Int?
    let serial: Int?
    let manufacturer: String?
    private let lock = NSLock()

    init(service: CFTypeRef, productID: Int?, serial: Int?, manufacturer: String?) {
        self.service = service
        self.productID = productID
        self.serial = serial
        self.manufacturer = manufacturer
    }

    static func discover() -> [DDCService] {
        var found: [DDCService] = []
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var attrs: [String: Any]?
        while case let entry = IORegistryIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            let name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("AppleCLCD2") || name.hasPrefix("IOMobileFramebufferShim") || name.hasPrefix("dispext") {
                let raw = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                attrs = (raw as? [String: Any])?["ProductAttributes"] as? [String: Any]
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                guard location == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append(DDCService(
                    service: av,
                    productID: attrs?["ProductID"] as? Int,
                    serial: attrs?["SerialNumber"] as? Int,
                    manufacturer: attrs?["ManufacturerID"] as? String
                ))
                attrs = nil
            }
        }
        return found
    }

    /// Best match for a CG display: product + serial, then product, then the
    /// first unused service.
    static func match(_ id: CGDirectDisplayID, in services: [DDCService], excluding used: Set<Int>) -> Int? {
        let model = Int(CGDisplayModelNumber(id))
        let serial = Int(CGDisplaySerialNumber(id))
        let candidates = services.indices.filter { !used.contains($0) }
        if let i = candidates.first(where: { services[$0].productID == model && services[$0].serial == serial && serial != 0 }) { return i }
        if let i = candidates.first(where: { services[$0].productID == model }) { return i }
        return candidates.first
    }

    func read(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<3 {
            var packet = DDC.getPacket(vcp)
            guard IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess else { continue }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            if let r = DDC.parseReply(reply, vcp: vcp) { return r }
            usleep(20_000)
        }
        return nil
    }

    func write(_ vcp: UInt8, _ value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var packet = DDC.setPacket(vcp, value)
        for _ in 0..<2 {
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { return true }
            usleep(20_000)
        }
        return false
    }
}

// MARK: - Software dimming (monitors without DDC)

enum SoftwareDimming {
    /// Scales the gamma curve; 1 restores the display's own curve.
    static func apply(_ id: CGDirectDisplayID, _ level: Double) {
        if level >= 0.999 {
            CGDisplayRestoreColorSyncSettings()
            return
        }
        let max = Float(0.15 + 0.85 * level)
        CGSetDisplayTransferByFormula(id, 0, max, 1, 0, max, 1, 0, max, 1)
    }
}

// MARK: - Night Shift (CoreBrightness's CBBlueLightClient)

enum NightShift {
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias GetStrength = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetStrength = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool

    nonisolated(unsafe) private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }()

    private static func imp<T>(_ name: String, _: T.Type) -> T? {
        guard let client, client.responds(to: Selector(name)) else { return nil }
        return unsafeBitCast(client.method(for: Selector(name)), to: T.self)
    }

    static func status() -> (on: Bool, strength: Float)? {
        guard let client, let getStatus = imp("getBlueLightStatus:", GetStatus.self),
              let getStrength = imp("getStrength:", GetStrength.self) else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        var strength: Float = 0
        guard getStatus(client, Selector(("getBlueLightStatus:")), buffer),
              getStrength(client, Selector(("getStrength:")), &strength) else { return nil }
        // Second byte: on right now (the first stays set while a schedule exists).
        return (buffer.load(fromByteOffset: 1, as: UInt8.self) != 0, strength)
    }

    static func setEnabled(_ on: Bool) {
        guard let client, let f = imp("setEnabled:", SetEnabled.self) else { return }
        _ = f(client, Selector(("setEnabled:")), on)
    }

    static func setStrength(_ value: Float) {
        guard let client, let f = imp("setStrength:commit:", SetStrength.self) else { return }
        _ = f(client, Selector(("setStrength:commit:")), value, true)
    }
}
#endif
