import AppKit
import SwiftUI
import GizmoCore

/// The mark at the start of the bar. Defaults to the Gizmobar app icon;
/// `[logo] image` swaps in any SVG/PNG/PDF, `text` adds a word mark.
struct LogoWidget: View {
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let logo = store.config.logo
        let theme = store.theme
        HStack(spacing: 6) {
            LogoImage(settings: logo, theme: theme)
                .frame(width: logo.size, height: logo.size)
            if let text = logo.text, !text.isEmpty {
                Text(text)
                    .font(.custom(theme.font, size: theme.fontSize + 3).weight(.semibold))
                    .foregroundStyle(Color(hex: tintHex(logo.tint, theme) ?? theme.icon))
            }
        }
        .padding(.horizontal, 4)
        .scaleEffect(hovering ? 1.08 : 1)
        .brightness(hovering ? 0.08 : 0)
        .animation(.snappy(duration: 0.15), value: hovering)
        .barAction(onHover: { hovering = $0 }, hasAction(logo) ? { @MainActor in activate(logo) } : nil)
        .help("Gizmobar")
    }

    private func hasAction(_ logo: LogoSettings) -> Bool {
        logo.url != nil || logo.command != nil
    }

    private func activate(_ logo: LogoSettings) {
        if let s = logo.url, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        } else if let command = logo.command {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            try? p.run()
        }
    }
}

private struct LogoImage: View {
    let settings: LogoSettings
    let theme: Theme

    var body: some View {
        if let image = LogoCache.shared.image(for: settings.image) {
            if let tint = tintHex(settings.tint, theme), image.isTemplate {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(Color(hex: tint))
            } else {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        } else {
            Image(systemName: "globe").resizable().scaledToFit()
                .foregroundStyle(Color(hex: theme.accent))
        }
    }
}

private func tintHex(_ tint: String?, _ theme: Theme) -> String? {
    tint == "accent" ? theme.accent : tint
}

@MainActor
final class LogoCache {
    static let shared = LogoCache()
    private var cache: [String: NSImage] = [:]

    /// nil path → the app's own icon (from the bundle's AppIcon.icns).
    func image(for path: String?) -> NSImage? {
        let key = path ?? "<app-icon>"
        if let hit = cache[key] { return hit }
        let image: NSImage?
        if let path {
            image = NSImage(contentsOf: GizmoPaths.expand(path))
            // Treat single-color SVGs as templates so `tint` works.
            if path.lowercased().hasSuffix(".svg") { image?.isTemplate = true }
        } else if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            image = NSImage(contentsOf: url)
        } else {
            image = nil // running unbundled (swift run): falls back to a symbol
        }
        if let image { cache[key] = image }
        return image
    }

    func invalidate() { cache.removeAll() }
}
