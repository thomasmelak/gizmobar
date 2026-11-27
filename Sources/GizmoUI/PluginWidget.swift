import AppKit
import SwiftUI
import GizmoCore

/// Plugin trees for the UI. The app fills it from the plugin manager and
/// routes callbacks back.
@MainActor
@Observable
public final class PluginStore {
    public var trees: [String: PluginNode] = [:]
    @ObservationIgnored public var invoke: ((String, Int, JSONValue) -> Void)?
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
                    .barAction(onClick.map { id in { plugins.invoke?(plugin, id, .null) } })
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
            PopupRow(icon: icon ?? "circle", text: label, action: onClick.map { id in { plugins.invoke?(plugin, id, .null) } })
        case .scene(let options, _, _):
            SceneSlot(options: options)
        case .spacer:
            Spacer(minLength: 0)
        case .error(let msg):
            Text("⚠︎ \(plugin)").font(.caption).foregroundStyle(Color(hex: t.bad)).help(msg)
        }
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
    @State private var popoverTree: PluginNode?

    var body: some View {
        Pill(focused: focused || showing, hovered: hovering && (onClick != nil || popover != nil)) {
            PluginNodeView(plugin: plugin, node: child, inPopover: false)
        }
        .barAction(onHover: { hovering = $0 }, action)
        .barPopover(id: "plugin.\(plugin)", isPresented: $showing) {
            if let popoverTree {
                PluginNodeView(plugin: plugin, node: popoverTree, inPopover: true).frame(minWidth: 220, alignment: .leading)
            }
        }
    }

    private var action: (@MainActor () -> Void)? {
        guard onClick != nil || popover != nil else { return nil }
        return {
            if let onClick { plugins.invoke?(plugin, onClick, .null) }
            if let popover {
                if showing { showing = false; return }
                Task {
                    popoverTree = await plugins.popover?(plugin, popover)
                    showing = true
                }
            }
        }
    }
}

/// Where a 3D scene draws (Phase 5 fills it in).
struct SceneSlot: View {
    let options: JSONValue
    var body: some View {
        Image(systemName: "cube.transparent").font(.system(size: 14, weight: .light))
    }
}
