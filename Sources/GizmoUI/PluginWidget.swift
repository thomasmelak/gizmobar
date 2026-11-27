import AppKit
import SwiftUI
import GizmoCore
import GizmoScene

/// Plugin trees for the UI. The app fills it from the plugin manager and
/// routes callbacks back.
@MainActor
@Observable
public final class PluginStore {
    public var trees: [String: PluginNode] = [:]
    /// Each plugin's folder, for model paths.
    public var directories: [String: URL] = [:]
    /// The latest `ctx.scene.play/set` per plugin.
    public var sceneCommands: [String: SceneCommand] = [:]
    @ObservationIgnored public var invoke: ((String, Int, JSONValue) -> Void)?
    /// Delivers a topic to a plugin's `ctx.on` handlers.
    @ObservationIgnored public var dispatch: ((String, String, JSONValue) -> Void)?
    @ObservationIgnored public var popover: ((String, Int) async -> PluginNode)?

    public init() {}
}

/// Draws a plugin's tree natively. Any node with a handler gets the
/// pointer cursor and hover styling, like built-in widgets.
struct PluginWidget: View {
    let id: String
    @Environment(BarStore.self) private var store
    @Environment(PluginStore.self) private var plugins

    var body: some View {
        if let node = plugins.trees[id] {
            PluginNodeView(plugin: id, node: node, inPopover: false)
        }
    }
}

struct PluginNodeView: View {
    let plugin: String
    let node: PluginNode
    let inPopover: Bool
    @Environment(BarStore.self) private var store
    @Environment(PluginStore.self) private var plugins

    var body: some View {
        content
    }

    private var tokens: [String: String] {
        let t = store.theme
        return ["accent": t.accent, "icon": t.icon, "label": t.label, "good": t.good, "warn": t.warn, "bad": t.bad,
                "netUp": t.netUp, "netDown": t.netDown]
    }

    private func color(_ c: String?, _ fallback: String) -> Color {
        Color(hex: PluginNode.color(c, theme: tokens) ?? fallback)
    }

    @ViewBuilder private var content: some View {
        let t = store.theme
        switch node {
        case .row(let kids, let gap):
            HStack(spacing: gap ?? 6) { children(kids) }
        case .column(let kids, let gap):
            VStack(alignment: .leading, spacing: gap ?? 2) { children(kids) }
        case .pill(let child, let focused, let onClick, let popover):
            if inPopover {
                PluginNodeView(plugin: plugin, node: child, inPopover: true)
                    .barAction(callback(onClick))
            } else {
                PluginPill(plugin: plugin, child: child, focused: focused, onClick: onClick, popover: popover)
            }
        case .text(let s, let c, let size, let marquee, let mono):
            let font = Font.custom(t.font, size: size ?? t.fontSize)
            if marquee {
                Marquee(text: s, scrolling: true).font(mono ? font.monospacedDigit() : font)
                    .foregroundStyle(color(c, t.label)).frame(maxWidth: 160)
            } else {
                Text(s).font(mono ? font.monospacedDigit() : font).foregroundStyle(color(c, t.label)).lineLimit(1)
            }
        case .icon(let name, let c, let size):
            Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "questionmark.square.dashed")
                .font(.system(size: size ?? 14, weight: .light))
                .foregroundStyle(color(c, t.icon))
        case .image(let src, let size, let radius):
            let s = size ?? 18
            Group {
                if let image = NSImage(contentsOfFile: (src as NSString).expandingTildeInPath) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color(hex: t.itemBorder)
                }
            }
            .frame(width: s, height: s)
            .clipShape(RoundedRectangle(cornerRadius: radius ?? 4))
        case .appIcon(let bundleID, _):
            AppIconView(app: AppRef(bundleID: bundleID, name: bundleID), size: 16)
        case .graph(let values, let c, let width):
            Sparkline(values: values, color: PluginNode.color(c, theme: tokens) ?? t.accent, width: width ?? 56)
        case .slider(let v, let onChange):
            BarSlider(value: v, tint: t.accent) { nv in if let onChange { plugins.invoke?(plugin, onChange, .number(nv)) } }
                .frame(width: 160)
        case .toggle(let on, let onChange):
            BarSwitch(isOn: on) { if let onChange { plugins.invoke?(plugin, onChange, .bool(!on)) } }
        case .button(let label, let icon, let onClick):
            PopupRow(icon: icon ?? "circle", text: label, action: callback(onClick))
        case .scene(let options, let onClick, let popover):
            SceneSlot(plugin: plugin, options: options, onClick: onClick, popover: popover, inPopover: inPopover)
        case .spacer:
            Spacer(minLength: 0)
        case .error(let msg):
            Text("⚠︎ \(plugin)").font(.caption).foregroundStyle(Color(hex: t.bad)).help(msg)
        }
    }

    private func callback(_ id: Int?) -> (@MainActor () -> Void)? {
        guard let id else { return nil }
        let plugins = self.plugins, plugin = self.plugin
        return { @MainActor in plugins.invoke?(plugin, id, .null) }
    }

    private func children(_ kids: [PluginNode]) -> some View {
        ForEach(Array(kids.enumerated()), id: \.offset) { _, k in
            PluginNodeView(plugin: plugin, node: k, inPopover: inPopover)
        }
    }
}

private struct PluginPill: View {
    let plugin: String
    let child: PluginNode
    let focused: Bool
    let onClick: Int?
    let popover: Int?
    @Environment(PluginStore.self) private var plugins
    @State private var showing = false
    @State private var hovering = false
    @State private var live = LivePopover()

    var body: some View {
        Pill(focused: focused || showing, hovered: hovering && (onClick != nil || popover != nil)) {
            PluginNodeView(plugin: plugin, node: child, inPopover: false)
        }
        .barAction(onHover: { hovering = $0 }, action)
        .barPopover(id: "plugin.\(plugin)", isPresented: $showing) {
            LivePopoverTree(plugin: plugin, live: live)
        }
        // Re-ask for the popover whenever the plugin renders, so an open
        // (or pinned) popover keeps up.
        .onChange(of: plugins.trees[plugin]) {
            guard showing, let popover else { return }
            Task { live.tree = await plugins.popover?(plugin, popover) }
        }
    }

    private var action: (@MainActor () -> Void)? {
        guard onClick != nil || popover != nil else { return nil }
        return {
            if let onClick { plugins.invoke?(plugin, onClick, .null) }
            if let popover {
                if showing { showing = false; return }
                Task {
                    live.tree = await plugins.popover?(plugin, popover)
                    showing = true
                }
            }
        }
    }
}

/// A plugin's `ui.scene`/`ui.globe`: the dot globe, or a model from the
/// plugin folder. Clicks reach `onClick` and `ctx.on("scene.click")`.
struct SceneSlot: View {
    let plugin: String
    let options: JSONValue
    let onClick: Int?
    let popover: Int?
    let inPopover: Bool
    @Environment(BarStore.self) private var store
    @Environment(PluginStore.self) private var plugins
    @State private var showing = false
    @State private var live = LivePopover()

    var body: some View {
        let o = SceneOptions.parse(options)
        let size = inPopover ? (o.popoverSize ?? max(o.size, 200)) : min(o.size, store.config.bar.height - 6)
        content(o, size: size, orbit: inPopover || showing)
            .frame(width: size, height: size)
            .overlay(PointerArea(pointer: onClick != nil || popover != nil || o.popoverSize != nil, onHover: nil))
            .help(inPopover ? "" : (o.caption ?? ""))
            // A model on its own floats without the popover's panel.
            .barPopover(id: "scene.\(plugin)", isPresented: $showing, chrome: popover != nil) {
                LiveScenePopover(plugin: plugin, live: live) { o, s in
                    content(o, size: s, orbit: o.orbit)
                }
            }
            // The popover follows the plugin's latest render (caption, model
            // state, popover tree) while it's open, pinned or not.
            .onAppear { live.options = options }
            .onChange(of: options) { live.options = options }
            .onChange(of: plugins.trees[plugin]) {
                guard showing, !inPopover, let popover, live.tree != nil else { return }
                Task { live.tree = await plugins.popover?(plugin, popover) }
            }
    }

    @ViewBuilder
    private func content(_ o: SceneOptions, size: CGFloat, orbit: Bool) -> some View {
        if o.builtin == "globe" {
            GlobeView(size: size, markers: o.markers, spin: o.spin, showLabels: size > 100, draggable: orbit)
                .onTapGesture { clicked(nil, o) }
        } else if let model = o.model, let dir = plugins.directories[plugin] {
            let url = model.hasPrefix("/") || model.hasPrefix("~") ? GizmoPaths.expand(model) : dir.appendingPathComponent(model)
            ModelSceneView(url: url, options: o, orbit: orbit,
                           onClick: { part in clicked(part, o) },
                           onLoaded: { clips in plugins.dispatch?(plugin, "scene.loaded", ["clips": .array(clips.map(JSONValue.string))]) },
                           command: plugins.sceneCommands[plugin])
        } else {
            Image(systemName: "cube.transparent").font(.system(size: 14, weight: .light))
        }
    }

    private func clicked(_ part: String?, _ o: SceneOptions) {
        plugins.dispatch?(plugin, "scene.click", part.map(JSONValue.string) ?? .null)
        if let onClick { plugins.invoke?(plugin, onClick, part.map(JSONValue.string) ?? .null) }
        guard !inPopover else { return }
        if showing { showing = false; return }
        if let popover {
            Task {
                live.tree = await plugins.popover?(plugin, popover)
                showing = true
            }
        } else if o.popoverSize != nil {
            live.tree = nil
            showing = true
        }
    }
}

/// What an open plugin popover shows, kept current by the item on the bar.
/// The popover's panel holds onto this box, so updates reach it.
@MainActor @Observable
final class LivePopover {
    var tree: PluginNode?
    var options: JSONValue = .null
}

private struct LivePopoverTree: View {
    let plugin: String
    let live: LivePopover

    var body: some View {
        if let tree = live.tree {
            PluginNodeView(plugin: plugin, node: tree, inPopover: true).frame(minWidth: 220, alignment: .leading)
        }
    }
}

private struct LiveScenePopover<Scene: View>: View {
    let plugin: String
    let live: LivePopover
    @ViewBuilder let scene: (SceneOptions, CGFloat) -> Scene
    @Environment(BarStore.self) private var store

    var body: some View {
        let o = SceneOptions.parse(live.options)
        if live.tree != nil {
            LivePopoverTree(plugin: plugin, live: live)
        } else if let s = o.popoverSize {
            VStack(spacing: 8) {
                scene(o, s).frame(width: s, height: s)
                if let c = o.caption {
                    Text(c).font(.custom(store.theme.font, size: store.theme.fontSize))
                        .foregroundStyle(Color(hex: store.theme.label))
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                }
            }
        }
    }
}
