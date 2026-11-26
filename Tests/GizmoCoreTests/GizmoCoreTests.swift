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
