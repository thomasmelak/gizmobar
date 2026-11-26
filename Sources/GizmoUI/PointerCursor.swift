import AppKit
import SwiftUI

/// Pointer cursor that works on the bar.
///
/// The bar's panel never becomes key and the app is never active, so
/// SwiftUI hover cursors and AppKit cursor rects are ignored: macOS only
/// lets the frontmost app change the cursor. Two things fix that:
/// 1. `BackgroundCursor.enable()` sets the window server connection property
///    other bars and window managers use ("SetsCursorInBackground"), which
///    lets this app set the cursor while another app is active.
/// 2. An AppKit tracking area with `.activeAlways` sets the cursor on enter
///    and on every move, and restores the arrow on exit.
public enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// Call once at launch. Resolved at runtime so a missing private symbol
    /// only costs the pointer cursor, never a crash.
    @MainActor
    public static func enable() {
        guard
            let connSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
            let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty")
        else { return }
        let conn = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let set = unsafeBitCast(setSym, to: SetProperty.self)
        _ = set(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

/// Transparent to clicks; tracks the pointer, sets the cursor and reports
/// hover. SwiftUI's own hover tracking isn't reliable in a panel of an app
/// that's never active, so hover styling uses this too.
final class PointerTrackingView: NSView {
    var cursor: NSCursor? = .pointingHand
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil
        )
        addTrackingArea(a)
        area = a
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) {
        cursor?.set()
        onHover?(true)
    }

    override func mouseMoved(with event: NSEvent) { cursor?.set() }
    override func cursorUpdate(with event: NSEvent) { cursor?.set() }

    override func mouseExited(with event: NSEvent) {
        if cursor != nil { NSCursor.arrow.set() }
        onHover?(false)
    }
}

struct PointerArea: NSViewRepresentable {
    var pointer = true
    var onHover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> PointerTrackingView {
        let v = PointerTrackingView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ view: PointerTrackingView, context: Context) {
        view.cursor = pointer ? .pointingHand : nil
        view.onHover = onHover
    }
}
