import Foundation
import Observation
import GizmoCore

/// The UI's view of the world. Events from the bus are applied to a pure
/// `BarSnapshot`; SwiftUI observes the result. The bus already coalesces to
/// about one flush per frame, so views redraw at most that often.
@MainActor
@Observable
public final class BarStore {
    public private(set) var snapshot = BarSnapshot()
    public var config: GizmoConfig
    public var theme: Theme
    public var icons: IconResolver

    /// Set by the app: handles requests from widgets (refresh a provider,
    /// toggle Wi-Fi...). See `BarRequest`.
    @ObservationIgnored public var onRequest: (@MainActor (String) -> Void)?

    public func request(_ name: String) { onRequest?(name) }

    /// Set by the app: runs when a workspace pill is clicked.
    @ObservationIgnored public var onFocusWorkspace: (@MainActor (String) -> Void)?

    public init(config: GizmoConfig, theme: Theme, icons: IconResolver) {
        self.config = config
        self.theme = theme
        self.icons = icons
    }

    /// Swaps in a freshly loaded resolver and drops cached icon images, so
    /// edited SVGs show up immediately.
    public func invalidateIcons(_ resolver: IconResolver) {
        IconCache.shared.invalidate()
        LogoCache.shared.invalidate()
        icons = resolver
    }

    public func apply(_ event: BarEvent) {
        snapshot.apply(event)
    }

    /// Feeds bus events into the store until the stream ends.
    public func attach(to bus: EventBus) {
        Task { @MainActor [weak self] in
            for await event in await bus.subscribe() {
                self?.apply(event)
            }
        }
    }
}

/// Requests widgets send to the app (and, later, plugins via ctx.emit).
public enum BarRequest {
    public static let refreshConnectivity = "network.connectivity.refresh"
    public static let toggleWiFi = "network.wifi.toggle"
    public static let toggleBluetooth = "network.bluetooth.toggle"
    public static let batteryDetailsOn = "battery.details.on"
    public static let batteryDetailsOff = "battery.details.off"
    public static let toggleLowPower = "battery.lowpower.toggle"
    public static let toggleNoSleep = "battery.nosleep.toggle"
    public static let setChargeLimit = "battery.chargelimit.set"
    public static let toggleMute = "audio.mute.toggle"
    public static func setVolume(_ v: Double) -> String { "audio.volume:\(v)" }
    public static func selectOutput(_ id: UInt32) -> String { "audio.output:\(id)" }
}
