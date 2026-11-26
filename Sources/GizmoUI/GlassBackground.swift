import AppKit
import SwiftUI

/// Liquid Glass on macOS 26, a vibrancy blur before that.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: Double
    var enabled: Bool

    func makeNSView(context: Context) -> NSView {
        guard enabled else { return NSView() }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            view.layer?.cornerRadius = cornerRadius
        }
    }
}
