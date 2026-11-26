import AppKit
import SwiftUI
import GizmoCore

/// Renders an app icon through the icon resolver. Images are rasterised once
/// per (choice, size) and cached, so icons cost nothing per frame.
struct AppIconView: View {
    let app: AppRef
    var size: CGFloat = 18
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
                    .foregroundStyle(Color(hex: tint ?? store.theme.icon))
            } else {
                generic
            }
        case .glyph(let text, let font, let tint):
            Text(text)
                .font(.custom(font, size: size * 0.9))
                .foregroundStyle(Color(hex: tint ?? store.theme.icon))
        case .monogram(let letter, let color):
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Color(hex: color ?? store.theme.workspaceIcon))
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
