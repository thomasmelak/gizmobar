#if canImport(AppKit)
import AppKit
import CoreGraphics
import GizmoCore

/// Lists every display and owns brightness/contrast/volume control.
///
/// Phase 1 only enumerates displays (so the bar gets a panel on each).
/// Phase 2 fills in the controllers: DisplayServices for built-in and Apple
/// displays, DDC/CI over IOAVService for external monitors, and software
/// dimming for monitors without DDC.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public var id: CGDirectDisplayID
    public var name: String
    public var isBuiltIn: Bool
    public var frame: CGRect
}

public protocol DisplayController: Sendable {
    var displayID: CGDirectDisplayID { get }
    func brightness() async throws -> Double
    func setBrightness(_ value: Double) async throws
}

public enum DisplayControlError: Error {
    case unsupported
}

/// Placeholder until Phase 2: reports unsupported for every display.
public struct UnsupportedDisplayController: DisplayController {
    public let displayID: CGDirectDisplayID
    public func brightness() async throws -> Double { throw DisplayControlError.unsupported }
    public func setBrightness(_ value: Double) async throws { throw DisplayControlError.unsupported }
}

public enum Displays {
    @MainActor
    public static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return DisplayInfo(id: id, name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0, frame: screen.frame)
        }
    }

    public static func controller(for id: CGDirectDisplayID) -> any DisplayController {
        UnsupportedDisplayController(displayID: id)
    }
}
#endif
