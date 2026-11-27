import AppKit
import SwiftUI
import GizmoCore

/// A pill: the shared container every widget sits in. Each pill is its own
/// piece of glass on an otherwise transparent bar, tinted with the theme.
struct Pill<Content: View>: View {
    var focused = false
    /// Accent border while hovered, like SketchyBar's `hover.sh border`.
    var hovered = false
    @ViewBuilder var content: Content
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        let shape = RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
        content
            .padding(.horizontal, 10)
            .frame(height: store.config.bar.height - store.config.bar.margin * 2)
            .background {
                ZStack {
                    GlassBackground(cornerRadius: t.cornerRadius, enabled: store.config.bar.glass)
                    shape.fill(Color(hex: focused ? t.workspaceFocusBackground : t.itemBackground))
                }
                .clipShape(shape)
            }
            .overlay(
                RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
                    .strokeBorder(Color(hex: hovered ? t.accent : (focused ? t.workspaceFocusBorder : t.itemBorder)), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct BarMonitorKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The bar's display as AeroSpace numbers monitors (1-based index into
    /// `NSScreen.screens`); nil when one bar shows everything.
    var barMonitor: Int? {
        get { self[BarMonitorKey.self] }
        set { self[BarMonitorKey.self] = newValue }
    }
}

/// With `[aerospace] per_monitor` (the default) each display's bar shows only
/// the workspaces AeroSpace has on that monitor.
struct WorkspacesWidget: View {
    @Environment(BarStore.self) private var store
    @Environment(\.barMonitor) private var monitor

    var body: some View {
        let list = store.snapshot.visibleWorkspaces(store.config.aerospace, monitor: monitor)
        HStack(spacing: 6) {
            ForEach(list) { ws in
                WorkspacePill(ws: ws, current: ws.isFocused || (monitor != nil && ws.isVisible))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: list.map(\.id))
    }
}

/// On hover the number and every app icon turn the accent color, like
/// SketchyBar's `hover.sh workspace`.
private struct WorkspacePill: View {
    let ws: WorkspaceInfo
    /// Focused, or the workspace this bar's monitor is showing.
    let current: Bool
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        let numberColor = hovering ? t.accent : (current ? t.workspaceFocusIcon : t.workspaceIcon)
        Pill(focused: current) {
            HStack(spacing: 5) {
                Text(ws.id)
                    .font(.custom(t.font, size: t.fontSize).weight(.semibold))
                    .foregroundStyle(Color(hex: numberColor))
                ForEach(Array(ws.apps.prefix(store.config.aerospace.maxAppIcons).enumerated()), id: \.offset) { _, app in
                    AppIconView(app: app, size: 16, tintOverride: hovering ? t.accent : nil)
                }
            }
        }
        .barAction(onHover: { hovering = $0 }) { store.onFocusWorkspace?(ws.id) }
        .animation(.snappy(duration: 0.18), value: current)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// The one way to make something on the bar clickable: whole-frame hit
    /// area, pointing-hand cursor on hover, and the action on click. Every
    /// interactive element (built-in widgets, and plugin nodes with
    /// `onClick` in Phase 4) goes through this, so the cursor is consistent.
    /// `onHover` drives the hover styling (accent border, accent icons).
    func barAction(onHover: ((Bool) -> Void)? = nil, _ action: @escaping @MainActor () -> Void) -> some View {
        contentShape(Rectangle())
            .overlay(PointerArea(pointer: true, onHover: onHover))
            .onTapGesture { action() }
    }

    /// Like `barAction`, but only when there is an action; hover is still reported.
    @ViewBuilder
    func barAction(onHover: ((Bool) -> Void)? = nil, _ action: (@MainActor () -> Void)?) -> some View {
        if let action { barAction(onHover: onHover, action) } else { barHover(onHover) }
    }

    /// Hover tracking without the pointer, for non-clickable items.
    @ViewBuilder
    func barHover(_ onHover: ((Bool) -> Void)?) -> some View {
        if let onHover { overlay(PointerArea(pointer: false, onHover: onHover)) } else { self }
    }
}

struct FrontAppWidget: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        if let app = store.snapshot.frontApp {
            Pill {
                HStack(spacing: 6) {
                    AppIconView(app: app, size: 18)
                    Text(app.name)
                        .font(.custom(store.theme.font, size: store.theme.fontSize))
                        .foregroundStyle(Color(hex: store.theme.label))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Shown for ids in the layout that no built-in or plugin provides yet.
struct MissingWidget: View {
    let id: String
    @Environment(BarStore.self) private var store

    var body: some View {
        Pill {
            Text(id).font(.caption).foregroundStyle(Color(hex: store.theme.bad))
        }
    }
}

/// A layout id that isn't built in: a plugin with that id, or a marker.
struct PluginOrMissing: View {
    let id: String
    @Environment(PluginStore.self) private var plugins

    var body: some View {
        let pid = id.hasPrefix("plugin:") ? String(id.dropFirst(7)) : id
        if plugins.trees[pid] != nil { PluginWidget(id: pid) } else { MissingWidget(id: id) }
    }
}

enum WidgetRegistry {
    @MainActor @ViewBuilder
    static func view(for id: String) -> some View {
        switch id {
        case "logo": LogoWidget()
        case "workspaces": WorkspacesWidget()
        case "front_app": FrontAppWidget()
        case "clock": ClockWidget()
        case "system": SystemWidget()
        case "network": NetworkWidget()
        case "battery": BatteryWidget()
        case "brightness": BrightnessWidget()
        case "volume": VolumeWidget()
        case "theme": ThemeWidget()
        case "now_playing": NowPlayingWidget()
        case "globe": GlobeWidget()
        default: PluginOrMissing(id: id)
        }
    }
}
