import Foundation
import Testing
@testable import GizmoCore

@Suite struct ConfigTests {
    @Test func emptyCustomPackDisablesIt() throws {
        let c = try GizmoConfig.parse("[icons]\ncustom_pack = \"\"")
        #expect(c.icons.customPack == nil)
        #expect(c.icons.packOrder == ["sketchybar-app-font"])
    }

    @Test func emptyConfigUsesDefaults() throws {
        let c = try GizmoConfig.parse("")
        #expect(c == GizmoConfig())
        #expect(c.theme == "gizmo")
        #expect(c.layout.left == ["logo", "workspaces"])
        #expect(c.logo.image == nil)
        #expect(c.logo.size == 24)
        #expect(c.bar.position == .bottom)
        #expect(c.bar.height == 40)
    }

    @Test func parsesExample() throws {
        let c = try GizmoConfig.parse("""
        theme = "gizmo"
        launch_at_login = true

        [bar]
        position = "bottom"
        height = 40

        [layout]
        left = ["workspaces"]
        right = ["clock"]

        [icons]
        style = "system"
        custom_pack = "my-icons"
        fallback = "monogram"

        [icons.apps]
        "com.spotify.client" = { style = "system" }
        "dev.zed.Zed" = { file = "~/icons/zed.svg" }

        [logo]
        image = "~/logo.svg"
        text = "tefer"
        tint = "accent"

        [aerospace]
        mode = "callback"
        max_app_icons = 5
        """)
        #expect(c.launchAtLogin)
        #expect(c.layout.center == ["front_app"])
        #expect(c.icons.style == .system)
        #expect(c.icons.packOrder == ["my-icons", "sketchybar-app-font"])
        #expect(c.icons.fallback == .monogram)
        #expect(c.icons.apps["dev.zed.Zed"]?.file == "~/icons/zed.svg")
        #expect(c.logo == LogoSettings(image: "~/logo.svg", text: "tefer", tint: "accent"))
        #expect(c.aerospace.mode == .callback)
        #expect(c.aerospace.maxAppIcons == 5)
    }
}

@Suite struct ClockTests {
    let posix = Locale(identifier: "en_US_POSIX")
    // 2026-11-26 21:11:31 UTC = Fri 27 Nov 00:11:31 in Addis Ababa, 16:11 EST
    let now = Date(timeIntervalSince1970: 1_795_727_491)
    let addis = TimeZone(identifier: "Africa/Addis_Ababa")!

    @Test func defaultMatchesSketchyBar() {
        let text = ClockText.bar(now, ClockSettings(), locale: posix, local: addis)
        #expect(text == "Fri 27 Nov 00:11:31 | 16:11 EST")
    }

    @Test func labelsAndMultipleInlineClocks() {
        let s = ClockSettings(format: "HH:mm", world: [
            WorldClock(zone: "Europe/London", label: "LDN", inline: true),
            WorldClock(zone: "Asia/Tokyo", inline: false),
        ])
        #expect(ClockText.bar(now, s, locale: posix, local: addis) == "00:11 | 21:11 LDN")
    }

    @Test func zoneAbbreviationsLikeDate() {
        #expect(WorldClock(zone: "America/New_York").abbreviation(at: now) == "EST")
        #expect(WorldClock(zone: "UTC").abbreviation(at: now) == "UTC")
        #expect(WorldClock(zone: "Etc/UTC").abbreviation(at: now) == "UTC")
        #expect(ClockText.inline(now, WorldClock(zone: "UTC"), locale: posix) == "21:11 UTC")
    }

    @Test func dayOffset() {
        #expect(ClockText.dayOffset(now, WorldClock(zone: "America/New_York"), local: addis) == -1)
        #expect(ClockText.dayOffset(now, WorldClock(zone: "Europe/Moscow"), local: addis) == 0)
    }

    @Test func parsesWorldClocks() throws {
        let c = try GizmoConfig.parse("""
        [clock]
        format = "HH:mm"
        [[clock.world]]
        zone = "Asia/Tokyo"
        label = "TYO"
        inline = true
        """)
        #expect(c.clock.format == "HH:mm")
        #expect(c.clock.world == [WorldClock(zone: "Asia/Tokyo", label: "TYO", inline: true)])
        #expect(try GizmoConfig.parse("").clock.world == ClockSettings.defaultWorld)
    }

    @Test func monthGridStartsMonday() {
        let g = MonthGrid(for: now, zone: addis, locale: posix)
        #expect(g.title == "November 2026")
        #expect(g.today == 27)
        // 1 Nov 2026 is a Sunday: six blanks first.
        #expect(g.weeks[0] == [nil, nil, nil, nil, nil, nil, 1])
        #expect(g.weeks.count == 6)
    }
}

@Suite struct ThemeTests {
    @Test func hexParsing() {
        #expect(RGBA(hex: "#ff0000") == RGBA(r: 1, g: 0, b: 0, a: 1))
        #expect(RGBA(hex: "#00000000")?.a == 0)
        // SketchyBar order: 0xAARRGGBB
        let c = RGBA(hex: "0x80ff0000")
        #expect(c?.r == 1)
        #expect(abs((c?.a ?? 0) - 128.0 / 255) < 0.001)
        #expect(RGBA(hex: "nope") == nil)
    }
}

@Suite struct EventBusTests {
    @Test func coalescesLatestPerTopicAndKey() async {
        let bus = EventBus(flushWindow: .seconds(60))
        let stream = await bus.subscribe(prefixes: ["aerospace"])
        await bus.publish(topic: "aerospace.focus-changed", payload: ["workspace": "1"])
        await bus.publish(topic: "aerospace.focus-changed", payload: ["workspace": "2"])
        await bus.publish(topic: "aerospace.focus-changed", payload: ["workspace": "3"])
        await bus.publish(topic: "clock.tick", payload: ["epoch": 1])
        await bus.flush()

        var it = stream.makeAsyncIterator()
        let first = await it.next()
        #expect(first?.payload["workspace"]?.string == "3")
        await bus.publish(topic: "aerospace.done")
        await bus.flush()
        let second = await it.next()
        #expect(second?.topic == "aerospace.done")
    }
}

@Suite struct SnapshotTests {
    @Test func buildsWorkspacesFromAeroSpace() {
        var s = BarSnapshot()
        s.apply(BarEvent(topic: Topic.aerospaceSnapshot, payload: [
            "workspaces": ["1", "2", "3"],
            "focused": "2",
            "windows": [
                ["window-id": 1, "workspace": "2", "app-bundle-id": "dev.zed.Zed", "app-name": "Zed"],
                ["window-id": 2, "workspace": "2", "app-bundle-id": "dev.zed.Zed", "app-name": "Zed"],
                ["window-id": 3, "workspace": "3", "app-bundle-id": "com.spotify.client", "app-name": "Spotify"],
            ],
        ]))
        #expect(s.workspaces.map(\.id) == ["1", "2", "3"])
        #expect(s.workspaces[1].isFocused)
        #expect(s.workspaces[1].apps.count == 1)
        #expect(s.workspaces[2].apps.first?.name == "Spotify")

        s.apply(BarEvent(topic: Topic.aerospaceFocusedWorkspace, payload: ["workspace": "3"]))
        #expect(s.focusedWorkspace == "3")
        #expect(s.workspaces[2].isFocused)
        #expect(!s.workspaces[1].isFocused)
    }

    @Test func hidesEmptyWorkspacesExceptFocused() {
        var s = BarSnapshot()
        s.apply(BarEvent(topic: Topic.aerospaceSnapshot, payload: [
            "workspaces": ["1", "2", "3"],
            "focused": "1",
            "windows": [["window-id": 1, "workspace": "3", "app-bundle-id": "dev.zed.Zed", "app-name": "Zed"]],
        ]))
        #expect(s.visibleWorkspaces(AeroSpaceSettings()).map(\.id) == ["1", "3"])
        #expect(s.visibleWorkspaces(AeroSpaceSettings(showFocusedWhenEmpty: false)).map(\.id) == ["3"])
        #expect(s.visibleWorkspaces(AeroSpaceSettings(hideEmpty: false)).map(\.id) == ["1", "2", "3"])
    }

    @Test func storesExternalTriggers() {
        var s = BarSnapshot()
        s.apply(BarEvent(topic: "vpn.status", payload: ["up": true]))
        #expect(s.triggers["vpn.status"]?["up"] == .bool(true))
    }
}

@Suite struct IconResolverTests {
    let tefer = IconPack(
        manifest: .init(id: "tefer-line", name: "Tefer Line", kind: .svg),
        root: URL(fileURLWithPath: "/packs/tefer-line"),
        colors: ["com.spotify.client": "#1db954"],
        aliases: ["Spotify": "com.spotify.client"],
        svgBundleIDs: ["com.spotify.client"]
    )
    let font = IconPack(
        manifest: .init(id: "sketchybar-app-font", name: "sketchybar-app-font", kind: .font, font: "sketchybar-app-font"),
        root: URL(fileURLWithPath: "/packs/sbaf"),
        glyphs: ["dev.zed.Zed": ":zed:"]
    )

    func resolver(_ s: IconSettings = IconSettings()) -> IconResolver {
        IconResolver(settings: s, packs: ["tefer-line": tefer, "sketchybar-app-font": font])
    }

    @Test func customPackFirst() {
        let r = resolver().resolve(bundleID: "com.spotify.client", appName: "Spotify")
        #expect(r.source == "tefer-line")
        #expect(r.choice == .svg(URL(fileURLWithPath: "/packs/tefer-line/icons/com.spotify.client.svg"), tint: "#1db954"))
    }

    @Test func fallsThroughToNextPack() {
        let r = resolver().resolve(bundleID: "dev.zed.Zed", appName: "Zed")
        #expect(r.source == "sketchybar-app-font")
    }

    @Test func fallbackWhenNoPackCoversApp() {
        let r = resolver().resolve(bundleID: "com.example.New", appName: "New")
        #expect(r.isFallback)
        #expect(r.choice == .system(bundleID: "com.example.New", mono: true))

        var s = IconSettings(); s.fallback = .monogram
        #expect(resolver(s).resolve(bundleID: "com.example.New", appName: "new").choice == .monogram("N", color: nil))
    }

    @Test func systemStyleSkipsPacks() {
        var s = IconSettings(); s.style = .system
        let r = resolver(s).resolve(bundleID: "com.spotify.client", appName: "Spotify")
        #expect(r.choice == .system(bundleID: "com.spotify.client", mono: false))
    }

    @Test func overrideWins() {
        var s = IconSettings()
        s.apps["com.spotify.client"] = AppIconOverride(style: .system)
        s.apps["dev.zed.Zed"] = AppIconOverride(file: "/tmp/zed.svg", color: "#ffffff")
        #expect(resolver(s).resolve(bundleID: "com.spotify.client", appName: "Spotify").source == "override")
        #expect(resolver(s).resolve(bundleID: "dev.zed.Zed", appName: "Zed").choice
            == .svg(URL(fileURLWithPath: "/tmp/zed.svg"), tint: "#ffffff"))
    }

    @Test func anyPackCanBeTheCustomOne() {
        var s = IconSettings()
        s.customPack = "sketchybar-app-font"
        s.packs = ["tefer-line"]
        // Zed is only in the font pack; Spotify only in tefer-line.
        #expect(resolver(s).resolve(bundleID: "dev.zed.Zed", appName: "Zed").source == "sketchybar-app-font")
        #expect(resolver(s).resolve(bundleID: "com.spotify.client", appName: "Spotify").source == "tefer-line")

        s.customPack = nil
        s.packs = []
        #expect(resolver(s).resolve(bundleID: "com.spotify.client", appName: "Spotify").isFallback)
    }

    @Test func aliasMapsNameToBundleID() {
        let r = resolver().resolve(bundleID: nil, appName: "Spotify")
        #expect(r.source == "tefer-line")
    }
}

@Suite struct PluginManifestTests {
    @Test func permissions() {
        let m = PluginManifest(id: "x", version: "1", entry: "dist/index.js", permissions: ["provider:*", "net:api.example.com"])
        #expect(m.allows("provider:cpu"))
        #expect(m.allows("net:api.example.com"))
        #expect(!m.allows("exec"))
    }
}

@Suite struct MetricsTests {
    @Test func speedLabelsMatchNetworkSh() {
        #expect(Units.speed(512) == "512 B/s")
        #expect(Units.speed(8_000) == "8.0 KB/s")
        #expect(Units.speed(1_234_567) == "1.2 MB/s")
        #expect(Units.speed(-5) == "0 B/s")
    }

    @Test func sizes() {
        #expect(Units.size(512 * 1_048_576) == "512 MB")
        #expect(Units.size(1536 * 1_048_576) == "1.5 GB")
        #expect(Units.usedOfTotal(12 * 1_073_741_824, 16 * 1_073_741_824) == "12.0 / 16 GB")
        #expect(Units.percent(0.256) == "26%")
    }

    @Test func historyFillsThenPushesOnlyChanges() {
        var h = History(capacity: 4)
        h.push(0.5)
        #expect(h.values == [0.5, 0.5, 0.5, 0.5])
        h.push(0.5)
        #expect(h.values == [0.5, 0.5, 0.5, 0.5])
        h.push(0.7)
        h.push(0.9)
        #expect(h.values == [0.5, 0.5, 0.7, 0.9])
    }

    @Test func signalQualityAndConnectionLabel() {
        var c = Connectivity(kind: .wifi, wifiPower: true, rssi: -60, channel: 36, band: "5 GHz")
        #expect(c.signal == .good)
        #expect(c.connectionLabel == "5 GHz · channel 36")
        c.rssi = -80
        #expect(c.signal == .weak)
        c.wifiPower = false
        #expect(c.signal == nil)
        #expect(c.connectionLabel == "Off")
        #expect(Connectivity(kind: .ethernet).connectionLabel == "Ethernet")
        #expect(Connectivity(wifiPower: true).connectionLabel == "Not connected")
    }

    @Test func bluetoothKinds() {
        #expect(BluetoothDevice.kind(minorType: "Headphones") == .headphones)
        #expect(BluetoothDevice.kind(minorType: "Mouse") == .mouse)
        #expect(BluetoothDevice.kind(minorType: nil) == .other)
    }

    @Test func snapshotKeepsChartHistory() {
        var s = BarSnapshot()
        let stats = SystemStats(cpu: 0.25, gpu: 0.1, temperature: 50, ramUsed: 8, ramTotal: 16, swapUsed: 0, swapTotal: 0)
        s.apply(BarEvent(topic: Topic.systemStats, payload: JSONValue(encoding: stats)))
        #expect(s.system == stats)
        #expect(s.cpuHistory.values.count == 56)
        #expect(s.temperatureHistory.values.last == 0.5)
        #expect(s.system?.ramFraction == 0.5)
        #expect(s.system?.swapInUse == false)

        s.apply(BarEvent(topic: Topic.networkSpeed, payload: JSONValue(encoding: NetworkSpeed(download: 100, upload: 5, interface: "en0"))))
        #expect(s.network.interface == "en0")
    }
}

@Suite struct PowerAudioTests {
    @Test func batteryLabelsMatchBatteryInfoSh() {
        var b = BatteryStatus(percent: 64, minutesToEmpty: 185, rateMilliwatts: -7400)
        #expect(b.stateLabel == "On battery")
        #expect(b.timeLabel == "3:05 left")
        #expect(b.drawLabel == "7.4 W")
        #expect(b.rateLabel == "-7.4 W")
        #expect(b.tone == .normal)
        #expect(b.symbol == "battery.75percent")

        b.minutesToEmpty = 65535
        #expect(b.timeLabel == "estimating")

        b = BatteryStatus(percent: 80, external: true, charging: true, minutesToFull: 42, rateMilliwatts: 25000, loadMilliwatts: 9000)
        #expect(b.stateLabel == "Charging")
        #expect(b.timeLabel == "0:42 to full")
        #expect(b.drawLabel == "9.0 W")
        #expect(b.rateLabel == "+25.0 W")
        #expect(b.tone == .charging)

        #expect(BatteryStatus(percent: 100, external: true, full: true).stateLabel == "Charged")
        #expect(BatteryStatus(percent: 100, external: true, full: true).timeLabel == "-")
        #expect(BatteryStatus(percent: 15).tone == .low)
        #expect(BatteryStatus(percent: 50, lowPower: true).tone == .saver)
    }

    @Test func audioSymbolsAndDeviceKinds() {
        #expect(AudioStatus(volume: 70, muted: false).symbol == "speaker.wave.3")
        #expect(AudioStatus(volume: 40, muted: false).symbol == "speaker.wave.2")
        #expect(AudioStatus(volume: 10, muted: false).symbol == "speaker.wave.1")
        #expect(AudioStatus(volume: 70, muted: true).symbol == "speaker.slash")
        #expect(AudioDevice(id: 1, name: "AirPods Pro", isCurrent: false).kind == .headphones)
        #expect(AudioDevice(id: 2, name: "DELL U2723QE", isCurrent: false).kind == .display)
        #expect(AudioDevice(id: 3, name: "MacBook Pro Speakers", isCurrent: true).kind == .speaker)
    }
}

@Suite("Displays")
struct DisplaysTests {
    @Test func ddcPackets() {
        #expect(DDC.getPacket(DDC.luminance) == [0x82, 0x01, 0x10, 0xFD])
        #expect(DDC.setPacket(DDC.luminance, 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    @Test func ddcReply() {
        var r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A]
        r.append(r.reduce(0x50, ^))
        let parsed = DDC.parseReply(r, vcp: DDC.luminance)
        #expect(parsed?.current == 42)
        #expect(parsed?.max == 100)
        #expect(DDC.parseReply(r, vcp: DDC.contrast) == nil)
        r[10] ^= 0xFF
        #expect(DDC.parseReply(r, vcp: DDC.luminance) == nil)
    }

    @Test func mainDisplay() {
        let s = DisplaysStatus(displays: [
            DisplayState(id: 1, name: "Built-in", isBuiltIn: true, isMain: false, control: .builtin, brightness: 70),
            DisplayState(id: 2, name: "LG", isBuiltIn: false, isMain: true, control: .ddc, brightness: 40, contrast: 75),
        ], nightShift: false, warmth: 50)
        #expect(s.main?.id == 2)
        var snap = BarSnapshot()
        snap.apply(BarEvent(topic: Topic.displays, payload: JSONValue(encoding: s)))
        #expect(snap.displays == s)
    }
}

@Suite("ConfigEditor")
struct ConfigEditorTests {
    let sample = """
    # Gizmobar config
    theme = "gizmo"   # see themes/

    [icons]
    custom_pack = "tefer-line"

    [bar]
    height = 32

    """

    @Test func replacesTopLevelKeepingComment() throws {
        let out = ConfigEditor.set("theme", ConfigEditor.string("nord"), in: sample)
        #expect(out.contains("theme = \"nord\"  # see themes/"))
        #expect(try GizmoConfig.parse(out).theme == "nord")
    }

    @Test func insertsTopLevelAfterLeadingComments() throws {
        let out = ConfigEditor.set("theme", ConfigEditor.string("nord"), in: "# hi\n\n[bar]\nheight = 30\n")
        #expect(out.hasPrefix("# hi\n\ntheme = \"nord\"\n[bar]"))
        #expect(try GizmoConfig.parse(out).bar.height == 30)
    }

    @Test func setsInTable() throws {
        let out = ConfigEditor.set("style", ConfigEditor.string("system"), table: "icons", in: sample)
        let c = try GizmoConfig.parse(out)
        #expect(c.icons.style == .system)
        #expect(c.icons.customPack == "tefer-line")
        #expect(c.bar.height == 32)
    }

    @Test func addsMissingTable() throws {
        let out = ConfigEditor.set("style", ConfigEditor.string("system"), table: "icons", in: "theme = \"nord\"\n")
        #expect(try GizmoConfig.parse(out).icons.style == .system)
    }
}

@Suite("Themes")
struct ThemeCatalogTests {
    @Test func bundledThemesParse() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("themes")
        let entries = Theme.catalog(in: [dir])
        #expect(entries.first?.id == "gizmo")
        #expect(entries.count == 12)
        #expect(Theme.load(named: "nord", in: dir).accent == "#88c0d0")
        #expect(Theme.load(named: "missing", in: dir) == .gizmo)
    }
}
