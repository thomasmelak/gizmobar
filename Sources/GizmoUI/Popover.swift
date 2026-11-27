import AppKit
import SwiftUI
import GizmoCore

/// Popovers are child panels anchored to their item: glass, themed, clamped
/// to the screen, above the bar (below it for a top bar). One is open at a
/// time; clicking anywhere outside closes it.
@MainActor
final class PopoverController {
    static let shared = PopoverController()

    private var panel: NSPanel?
    private var openID: String?
    private var onClose: (() -> Void)?
    private var monitors: [Any] = []

    func isOpen(_ id: String) -> Bool { openID == id }
    var anyOpen: Bool { openID != nil }

    func show(id: String, anchor: NSView, store: BarStore, root: AnyView, onClose: @escaping () -> Void) {
        close()
        guard let anchorWindow = anchor.window, let screen = anchorWindow.screen else {
            onClose()
            return
        }
        let t = store.theme
        let shape = RoundedRectangle(cornerRadius: t.cornerRadius + 4, style: .continuous)
        let content = root
            .padding(12)
            .background {
                ZStack {
                    GlassBackground(cornerRadius: t.cornerRadius + 4, enabled: store.config.bar.glass)
                    shape.fill(Color(hex: t.popupBackground))
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(Color(hex: t.popupBorder).opacity(0.6), lineWidth: 1))
            .font(.custom(t.font, size: t.fontSize))
            .foregroundStyle(Color(hex: t.label))
            .environment(store)
            .fixedSize()

        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        let p = PopoverPanel()
        p.contentViewController = host
        p.layoutIfNeeded()
        let size = host.view.fittingSize

        let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bounds = screen.frame.insetBy(dx: 8, dy: 0)
        var x = anchorRect.midX - size.width / 2
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        let gap: CGFloat = 6
        let y = store.config.bar.position == .bottom
            ? anchorWindow.frame.maxY + gap
            : anchorWindow.frame.minY - gap - size.height
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()

        panel = p
        openID = id
        self.onClose = onClose

        // Clicks in other apps close it. Clicks on the bar are left to the
        // items (clicking the same item toggles, another item replaces it).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
    }

    func close(id: String? = nil) {
        if let id, id != openID { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        openID = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

final class PopoverPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the NSView a popover is anchored to.
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

private struct BarPopoverModifier<P: View>: ViewModifier {
    let id: String
    @Binding var isPresented: Bool
    let popover: () -> P
    @Environment(BarStore.self) private var store
    @State private var anchor = AnchorBox()

    func body(content: Content) -> some View {
        content
            .background(AnchorView(box: anchor))
            .onChange(of: isPresented) { _, shown in
                if shown, let view = anchor.view {
                    PopoverController.shared.show(id: id, anchor: view, store: store, root: AnyView(popover())) {
                        isPresented = false
                    }
                } else if !shown {
                    PopoverController.shared.close(id: id)
                }
            }
    }
}

extension View {
    /// Shows `content` in an anchored popover panel while `isPresented`.
    func barPopover<P: View>(id: String, isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> P) -> some View {
        modifier(BarPopoverModifier(id: id, isPresented: isPresented, popover: content))
    }
}
