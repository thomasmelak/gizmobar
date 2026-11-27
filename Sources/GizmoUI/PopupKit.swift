import AppKit
import SwiftUI
import GizmoCore

/// Shared pieces for popovers, matching the SketchyBar popups: a header with
/// an icon, a title and an optional switch; rows with a 36 pt icon column
/// whose text turns the accent color on hover; line charts and pies.

struct PopupHeader<Trailing: View>: View {
    let icon: String
    let title: String
    var action: (@MainActor () -> Void)?
    @ViewBuilder var trailing: Trailing
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .light))
                .frame(width: 36, alignment: .leading)
            Text(title)
                .font(.custom(t.font, size: t.fontSize + 1).weight(.semibold))
            Spacer(minLength: 16)
            trailing
        }
        .foregroundStyle(Color(hex: hovering && action != nil ? t.label : t.accent))
        .padding(.bottom, 4)
        .barAction(onHover: { hovering = $0 }, action)
    }
}

extension PopupHeader where Trailing == EmptyView {
    init(icon: String, title: String, action: (@MainActor () -> Void)? = nil) {
        self.init(icon: icon, title: title, action: action) { EmptyView() }
    }
}

/// A row: icon column, text, then an optional accessory (chart, pie, switch).
struct PopupRow<Accessory: View>: View {
    let icon: String
    let text: String
    var color: String?
    var iconColor: String?
    var action: (@MainActor () -> Void)?
    @ViewBuilder var accessory: Accessory
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color(hex: iconColor ?? t.icon))
                .frame(width: 36, alignment: .leading)
            Text(text)
                .foregroundStyle(Color(hex: hovering && action != nil ? t.accent : (color ?? t.label)))
                .lineLimit(1)
            Spacer(minLength: 18)
            accessory
        }
        .frame(minHeight: 22)
        .barAction(onHover: { hovering = $0 }, action)
    }
}

extension PopupRow where Accessory == EmptyView {
    init(icon: String, text: String, color: String? = nil, iconColor: String? = nil, action: (@MainActor () -> Void)? = nil) {
        self.init(icon: icon, text: text, color: color, iconColor: iconColor, action: action) { EmptyView() }
    }
}

struct PopupDivider: View {
    @Environment(BarStore.self) private var store
    var body: some View {
        Rectangle().fill(Color(hex: store.theme.itemBorder)).frame(height: 1).padding(.vertical, 4)
    }
}

/// A 56×16 line chart with a soft fill, like SketchyBar's graph items.
struct Sparkline: View {
    let values: [Double]
    let color: String
    var width: CGFloat = 56
    var height: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            let c = Color(hex: color)
            ctx.fill(fill, with: .color(c.opacity(0.2)))
            ctx.stroke(line, with: .color(c), lineWidth: 1)
        }
        .frame(width: width, height: height)
    }
}

/// A small pie, accent normally and the alert color from 80% (pie.sh).
struct Pie: View {
    let fraction: Double
    var size: CGFloat = 16
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        let color = Color(hex: fraction >= 0.8 ? t.bad : t.accent)
        ZStack {
            Circle().fill(color.opacity(0.25))
            PieSlice(fraction: fraction).fill(color)
        }
        .frame(width: size, height: size)
        .frame(width: 56)
    }
}

private struct PieSlice: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * min(max(fraction, 0), 1)), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// An on/off switch drawn in the theme colors (SketchyBar's switch.sh).
/// A click flips it at once and spins in the knob until `isOn` follows,
/// so slow changes (Bluetooth, Wi-Fi) don't feel stuck. If nothing changes
/// within 10 s it settles back on the real state.
struct BarSwitch: View {
    let isOn: Bool
    let action: @MainActor () -> Void
    @Environment(BarStore.self) private var store
    @State private var pending: Bool?

    var body: some View {
        let t = store.theme
        let shown = pending ?? isOn
        Capsule()
            .fill(Color(hex: shown ? t.accent : t.itemBorder))
            .opacity(pending == nil ? 1 : 0.75)
            .frame(width: 30, height: 16)
            .overlay(alignment: shown ? .trailing : .leading) {
                ZStack {
                    Circle().fill(Color(hex: t.label)).frame(width: 12, height: 12)
                    if pending != nil {
                        SwitchSpinner(color: shown ? t.accent : t.itemBorder)
                            .frame(width: 8, height: 8)
                            .transition(.opacity)
                    }
                }
                .padding(2)
            }
            .animation(.snappy(duration: 0.15), value: shown)
            .animation(.easeOut(duration: 0.15), value: pending == nil)
            .onChange(of: isOn) { _, new in if pending == new { pending = nil } }
            .barAction {
                guard pending == nil else { return }
                let target = !isOn
                pending = target
                action()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    if pending == target { pending = nil }
                }
            }
    }
}

/// A small spinning arc.
private struct SwitchSpinner: View {
    let color: String
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Color(hex: color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// Opens Activity Monitor on a tab (activity_monitor.sh). It only reads its
/// tab at launch, so a running copy is quit first.
enum ActivityMonitor {
    enum Tab: Int { case cpu = 0, memory = 1, disk = 3 }

    @MainActor
    static func open(_ tab: Tab) {
        Task { @MainActor in
            let id = "com.apple.ActivityMonitor"
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
            for _ in 0..<20 where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            CFPreferencesSetAppValue("SelectedTab" as CFString, tab.rawValue as CFNumber, id as CFString)
            CFPreferencesAppSynchronize(id as CFString)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
    }
}

enum SystemSettings {
    @MainActor
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
