import SwiftUI
import GizmoCore

/// Palette icon. Click for the Theme popover: every theme (the current one
/// checked, in the accent color) and a switch between your custom icons and
/// system icons. Picking saves to config.toml, which reloads the bar.
struct ThemeWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        Pill(focused: showing, hovered: hovering) {
            Image(systemName: "paintpalette")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Color(hex: hovering ? t.accent : t.icon))
                .frame(width: 18)
        }
        .barAction(onHover: { hovering = $0 }) { showing.toggle() }
        .barPopover(id: "theme", isPresented: $showing) { ThemePopover() }
        .onChange(of: showing) { _, open in
            if open { store.request(BarRequest.refreshThemes) }
        }
    }
}

struct ThemePopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        VStack(alignment: .leading, spacing: 6) {
            PopupHeader(icon: "paintpalette", title: "Theme")
            ForEach(store.themes) { entry in
                let current = entry.id == store.config.theme
                PopupRow(icon: current ? "checkmark.circle.fill" : "circle", text: entry.name,
                         color: current ? t.accent : nil, iconColor: current ? t.accent : t.label,
                         action: { store.request(BarRequest.setTheme(entry.id)) })
            }
            PopupDivider()
            PopupRow(icon: "square.grid.2x2", text: "Custom icons") {
                BarSwitch(isOn: store.config.icons.style == .custom) {
                    store.request(BarRequest.toggleIconStyle)
                }
            }
        }
        .frame(minWidth: 230)
    }
}
