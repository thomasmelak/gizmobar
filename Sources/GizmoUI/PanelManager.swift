import AppKit
import SwiftUI
import GizmoCore

/// A borderless, non-activating panel that joins every Space and stays put
/// in Mission Control.
final class BarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One panel per display, rebuilt whenever the display layout changes.
@MainActor
public final class PanelManager {
    private let store: BarStore
    private var panels: [NSScreen: BarPanel] = [:]
    private var observer: NSObjectProtocol?

    public init(store: BarStore) {
        self.store = store
    }

    public func start() {
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    public func rebuild() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
        let bar = store.config.bar
        let screens: [NSScreen] = bar.displays == .main ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let f = screen.frame
            let y = bar.position == .bottom ? f.minY : f.maxY - bar.height
            let frame = NSRect(x: f.minX, y: y, width: f.width, height: bar.height)
            let panel = BarPanel(frame: frame)
            let root = BarView().environment(store).environment(store.plugins)
            panel.contentView = NSHostingView(rootView: root)
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            panels[screen] = panel
        }
    }

    public var panelCount: Int { panels.count }
}
