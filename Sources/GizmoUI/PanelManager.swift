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
/// With `[bar] autohide`, a panel slides off its edge (over fullscreen
/// windows, or always) and back when the pointer touches that edge.
@MainActor
public final class PanelManager {
    private let store: BarStore
    private var panels: [NSScreen: BarPanel] = [:]
    private var observer: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var fullscreenPoll: Timer?
    /// Displays whose bar should be hidden right now, and the ones currently
    /// revealed by the pointer.
    private var wantsHidden = Set<CGDirectDisplayID>()
    private var revealed = Set<CGDirectDisplayID>()
    private var pendingReveal: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var pendingHide: [CGDirectDisplayID: Task<Void, Never>] = [:]

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
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Fullscreen transitions animate; look again once they settle.
                MainActor.assumeIsolated {
                    self?.updateAutoHide()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(700))
                        self?.updateAutoHide()
                    }
                }
            })
        }
        // Catches fullscreen video in a browser, which changes no Space.
        fullscreenPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAutoHide() }
        }
    }

    // MARK: Auto-hide

    /// Recomputes which bars should hide and applies it.
    public func updateAutoHide() {
        let mode = store.config.bar.autohide
        var hidden = Set<CGDirectDisplayID>()
        if mode != .never {
            let windows = mode == .fullscreen ? Self.normalWindowBounds() : []
            for screen in panels.keys {
                guard let id = screen.displayID else { continue }
                if mode == .always || AutoHideRules.isFullscreen(windows: windows, display: CGDisplayBounds(id)) {
                    hidden.insert(id)
                }
            }
        }
        guard hidden != wantsHidden else { return }
        wantsHidden = hidden
        revealed.formIntersection(hidden)
        for (screen, panel) in panels {
            guard let id = screen.displayID else { continue }
            place(panel, on: screen, shown: !hidden.contains(id) || revealed.contains(id), animated: true)
        }
        if hidden.isEmpty {
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
            mouseMonitor = nil
        } else if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        }
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let bottom = store.config.bar.position == .bottom
        let height = store.config.bar.height
        for (screen, panel) in panels {
            guard let id = screen.displayID, wantsHidden.contains(id) else { continue }
            let f = screen.frame
            if revealed.contains(id) {
                let keep = AutoHideRules.keepZone(screen: f, bottom: bottom, height: height).contains(p)
                if keep || PopoverController.shared.anyOpen {
                    pendingHide[id]?.cancel()
                    pendingHide[id] = nil
                } else if pendingHide[id] == nil {
                    pendingHide[id] = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled, let self else { return }
                        self.pendingHide[id] = nil
                        guard !PopoverController.shared.anyOpen else { return }
                        self.revealed.remove(id)
                        self.place(panel, on: screen, shown: false, animated: true)
                    }
                }
            } else if AutoHideRules.triggerZone(screen: f, bottom: bottom).contains(p) {
                guard pendingReveal[id] == nil else { continue }
                // A short dwell, so passing over the edge doesn't flash the bar.
                pendingReveal[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self else { return }
                    self.pendingReveal[id] = nil
                    guard !Task.isCancelled,
                          AutoHideRules.triggerZone(screen: f, bottom: bottom, thickness: 6).contains(NSEvent.mouseLocation) else { return }
                    self.revealed.insert(id)
                    self.place(panel, on: screen, shown: true, animated: true)
                }
            }
        }
    }

    private func frame(on screen: NSScreen, shown: Bool) -> NSRect {
        let bar = store.config.bar
        let f = screen.frame
        let y: CGFloat
        switch (bar.position, shown) {
        case (.bottom, true): y = f.minY
        case (.bottom, false): y = f.minY - bar.height
        case (.top, true): y = f.maxY - bar.height
        case (.top, false): y = f.maxY
        }
        return NSRect(x: f.minX, y: y, width: f.width, height: bar.height)
    }

    private func place(_ panel: BarPanel, on screen: NSScreen, shown: Bool, animated: Bool) {
        let target = frame(on: screen, shown: shown)
        guard panel.frame != target else { return }
        guard animated else { return panel.setFrame(target, display: true) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = shown ? 0.18 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Bounds of on-screen app windows (layer 0), in global display coordinates.
    static func normalWindowBounds() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return rect
        }
    }

    public func rebuild() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
        let bar = store.config.bar
        let screens: [NSScreen] = bar.displays == .main ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let hidden = screen.displayID.map { wantsHidden.contains($0) && !revealed.contains($0) } ?? false
            let frame = frame(on: screen, shown: !hidden)
            let panel = BarPanel(frame: frame)
            let root = BarView().environment(store).environment(store.plugins)
            panel.contentView = NSHostingView(rootView: root)
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            panels[screen] = panel
        }
        updateAutoHide()
    }

    public var panelCount: Int { panels.count }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
