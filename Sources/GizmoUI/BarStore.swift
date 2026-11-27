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
    /// Plugin widget trees.
    @ObservationIgnored public let plugins = PluginStore()
    /// A source picked in the now playing popover (a player or any app
    /// making sound); nil follows what's playing.
    public var pickedSource: String?

    /// What the now playing pill shows.
    public var shownSource: ShownSource? {
        ShownSource.choose(media: snapshot.nowPlaying, audio: snapshot.audioSources, picked: pickedSource)
    }

    /// Themes the picker offers; refreshed by the app when it opens.
    public var themes: [ThemeEntry] = []

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
    public static let refreshDisplays = "displays.refresh"
    public static let toggleNightShift = "displays.nightshift.toggle"
    public static func setBrightness(display: UInt32, _ v: Int) -> String { "displays.brightness:\(display),\(v)" }
    public static func setContrast(display: UInt32, _ v: Int) -> String { "displays.contrast:\(display),\(v)" }
    public static let refreshThemes = "theme.refresh"
    public static let toggleIconStyle = "icons.style.toggle"
    public static let openIconPacks = "icons.folder.open"
    public static func setAppIconStyle(_ bundleID: String, _ style: IconSettings.Style) -> String { "icons.app.style:\(bundleID),\(style.rawValue)" }
    public static func chooseAppIconFile(_ bundleID: String) -> String { "icons.app.file:\(bundleID)" }
    public static func resetAppIcon(_ bundleID: String) -> String { "icons.app.reset:\(bundleID)" }
    public static let mediaToggle = "media.toggle"
    public static let mediaNext = "media.next"
    public static let mediaPrevious = "media.previous"
    public static let mediaShuffle = "media.shuffle"
    public static let mediaRepeat = "media.repeat"
    public static func mediaSeek(_ seconds: Double) -> String { "media.seek:\(seconds)" }
    public static func mediaSelect(_ id: String) -> String { "media.select:\(id)" }
    public static func setTheme(_ id: String) -> String { "theme.set:\(id)" }
    public static func setWarmth(_ v: Int) -> String { "displays.warmth:\(v)" }
}
