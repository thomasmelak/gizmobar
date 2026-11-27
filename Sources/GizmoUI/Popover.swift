import AppKit
import SwiftUI
import GizmoCore

/// Popovers are child panels anchored to their item: glass, themed, clamped
/// to the screen, above the bar (below it for a top bar). One is open at a
/// time; clicking anywhere outside closes it unless it's pinned.
@MainActor
final class PopoverController {
    static let shared = PopoverController()

    /// Whether the open popover ignores outside clicks.
    let pin = PopoverPin()

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
            .modifier(CornerPin())
            .font(.custom(t.font, size: t.fontSize))
            .foregroundStyle(Color(hex: t.label))
            .environment(store)
            .environment(store.plugins)
            .environment(pin)
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
        let fromBottom = store.config.bar.position == .bottom
        p.anchor = PopoverPanel.Anchor(
            midX: anchorRect.midX, minX: bounds.minX, maxX: bounds.maxX,
            edge: fromBottom ? anchorWindow.frame.maxY + gap : anchorWindow.frame.minY - gap,
            growsUp: fromBottom)
        p.setFrame(NSRect(x: x, y: 0, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()

        panel = p
        openID = id
        self.onClose = onClose

        // Clicks in other apps close it unless pinned. Clicks on the bar are
        // left to the items (clicking the same item toggles, another item
        // replaces it).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pin.pinned else { return }
                self.close()
            }
        }) { monitors.append(global) }
    }

    func close(id: String? = nil) {
        if let id, id != openID { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        openID = nil
        pin.pinned = false
        let callback = onClose
        onClose = nil
        callback?()
    }
}

final class PopoverPanel: NSPanel {
    /// Where the panel sits: centered on the item (kept on screen) with its
    /// bar-side edge fixed, so it grows and shrinks away from the bar when
    /// its content changes size instead of moving.
    struct Anchor {
        var midX, minX, maxX: CGFloat
        /// The bar-side edge's y in screen coordinates.
        var edge: CGFloat
        /// Bottom bar: the panel's bottom stays on `edge` and it grows up.
        var growsUp: Bool
    }

    var anchor: Anchor?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(anchored(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(anchored(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func anchored(_ r: NSRect) -> NSRect {
        guard let a = anchor else { return r }
        var r = r
        r.origin.x = min(max(a.midX - r.width / 2, a.minX), a.maxX - r.width)
        r.origin.y = a.growsUp ? a.edge : a.edge - r.height
        return r
    }

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

@MainActor @Observable
final class PopoverPin {
    var pinned = false
}

/// Tells the popover container that a header already shows the pin.
struct HeaderPinKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Keeps the open popover up when you click elsewhere.
struct PinButton: View {
    @Environment(PopoverPin.self) private var pin
    @Environment(BarStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let t = store.theme
        Image(systemName: pin.pinned ? "pin.fill" : "pin")
            .font(.system(size: 10, weight: .medium))
            .rotationEffect(.degrees(pin.pinned ? 0 : 45))
            .foregroundStyle(Color(hex: pin.pinned ? t.accent : t.label).opacity(pin.pinned || hovering ? 1 : 0.45))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help(pin.pinned ? "Unpin" : "Pin open")
            .animation(.easeOut(duration: 0.15), value: pin.pinned)
            .barAction(onHover: { hovering = $0 }) { pin.pinned.toggle() }
    }
}

/// A pin in the corner for popovers without a header.
private struct CornerPin: ViewModifier {
    @State private var headerHasPin = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(HeaderPinKey.self) { headerHasPin = $0 }
            .overlay(alignment: .topTrailing) {
                if !headerHasPin { PinButton().padding(2) }
            }
    }
}
