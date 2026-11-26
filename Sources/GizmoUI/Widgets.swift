import SwiftUI
import GizmoCore

/// A pill: the shared container every widget sits in.
struct Pill<Content: View>: View {
    var focused = false
    @ViewBuilder var content: Content
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        content
            .padding(.horizontal, 10)
            .frame(height: store.config.bar.height - store.config.bar.margin * 2)
            .background(
                RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
                    .fill(Color(hex: focused ? t.workspaceFocusBackground : t.itemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
                    .strokeBorder(Color(hex: focused ? t.workspaceFocusBorder : t.itemBorder), lineWidth: 1)
            )
    }
}

struct WorkspacesWidget: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        HStack(spacing: 6) {
            ForEach(store.snapshot.workspaces) { ws in
                Pill(focused: ws.isFocused) {
                    HStack(spacing: 5) {
                        Text(ws.id)
                            .font(.custom(t.font, size: t.fontSize).weight(.semibold))
                            .foregroundStyle(Color(hex: ws.isFocused ? t.workspaceFocusIcon : t.workspaceIcon))
                        ForEach(Array(ws.apps.prefix(store.config.aerospace.maxAppIcons).enumerated()), id: \.offset) { _, app in
                            AppIconView(app: app, size: 16)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.onFocusWorkspace?(ws.id) }
                .animation(.snappy(duration: 0.18), value: ws.isFocused)
            }
        }
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

struct ClockWidget: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        Pill {
            Text(store.snapshot.now, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.custom(store.theme.font, size: store.theme.fontSize).monospacedDigit())
                .foregroundStyle(Color(hex: store.theme.label))
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

enum WidgetRegistry {
    @MainActor @ViewBuilder
    static func view(for id: String) -> some View {
        switch id {
        case "logo": LogoWidget()
        case "workspaces": WorkspacesWidget()
        case "front_app": FrontAppWidget()
        case "clock": ClockWidget()
        default: MissingWidget(id: id)
        }
    }
}
