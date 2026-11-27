import AppKit
import SwiftUI
import GizmoCore

/// Renders an app icon through the icon resolver. Images are rasterised once
/// per (choice, size) and cached, so icons cost nothing per frame.
struct AppIconView: View {
    let app: AppRef
    var size: CGFloat = 18
    /// Replaces the icon's tint (used for hover). System icons can't be tinted
    /// and are left as they are.
    var tintOverride: String? = nil
    @Environment(BarStore.self) private var store

    var body: some View {
        let resolved = store.icons.resolve(bundleID: app.bundleID, appName: app.name)
        icon(for: resolved.choice)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if store.config.icons.debugFallbacks && resolved.isFallback {
                    Circle().fill(Color(hex: store.theme.warn)).frame(width: 4, height: 4)
                }
            }
            .help(app.name)
            .contextMenu { if let id = app.bundleID { IconMenu(bundleID: id, name: app.name, resolved: resolved) } }
    }

    @ViewBuilder
    private func icon(for choice: IconChoice) -> some View {
        switch choice {
        case .system(let bundleID, let mono):
            if let image = IconCache.shared.systemIcon(bundleID: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .saturation(mono ? 0 : 1)
                    .opacity(mono ? 0.85 : 1)
            } else {
                generic
            }
        case .svg(let url, let tint):
            if let image = IconCache.shared.svg(url) {
                Image(nsImage: image).resizable().renderingMode(.template)
                    .foregroundStyle(Color(hex: tintOverride ?? tint ?? store.theme.icon))
            } else {
                generic
            }
        case .glyph(let text, let font, let tint):
            Text(text)
                .font(.custom(font, size: size * 0.9))
                .foregroundStyle(Color(hex: tintOverride ?? tint ?? store.theme.icon))
        case .monogram(let letter, let color):
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Color(hex: tintOverride ?? color ?? store.theme.workspaceIcon))
                .overlay(Text(String(letter)).font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(.white))
        case .generic:
            generic
        }
    }

    private var generic: some View {
        Image(systemName: "app.dashed").resizable().scaledToFit()
            .foregroundStyle(Color(hex: store.theme.workspaceIcon))
    }
}

/// Right-click menu on an app icon: pick where its icon comes from. Saved
/// as an `[icons.apps]` override in config.toml.
private struct IconMenu: View {
    let bundleID: String
    let name: String
    let resolved: ResolvedIcon
    @Environment(BarStore.self) private var store

    var body: some View {
        let s = store.config.icons
        let override = s.apps[bundleID]
        let packName = s.customPack.flatMap { store.icons.packs[$0]?.manifest.name } ?? "Custom Pack"
        Text(name)
        Toggle(packName, isOn: binding(resolved.source == s.customPack) {
            store.request(BarRequest.setAppIconStyle(bundleID, .custom))
        })
        Toggle("System Icon", isOn: binding(resolved.source == "override" && override?.style == .system || resolved.source == "system-style") {
            store.request(BarRequest.setAppIconStyle(bundleID, .system))
        })
        Button("Choose File…") { store.request(BarRequest.chooseAppIconFile(bundleID)) }
        Divider()
        if override != nil {
            Button("Reset to Default") { store.request(BarRequest.resetAppIcon(bundleID)) }
        }
        Button("Open Icon Packs Folder") { store.request(BarRequest.openIconPacks) }
    }

    private func binding(_ on: Bool, _ action: @escaping @MainActor () -> Void) -> Binding<Bool> {
        Binding(get: { on }, set: { _ in action() })
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var system: [String: NSImage] = [:]
    private var svgs: [URL: NSImage] = [:]

    func systemIcon(bundleID: String) -> NSImage? {
        if let hit = system[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        system[bundleID] = image
        return image
    }

    func svg(_ url: URL) -> NSImage? {
        if let hit = svgs[url] { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        svgs[url] = image
        return image
    }

    /// Called when packs or settings change on disk.
    func invalidate() {
        system.removeAll()
        svgs.removeAll()
    }
}
