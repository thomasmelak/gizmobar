import CoreGraphics

/// Pure decisions behind the bar's auto-hide, kept apart from AppKit so
/// they can be tested.
public enum AutoHideRules {
    /// True when a normal window covers the whole display (a fullscreen app
    /// or a fullscreen video). `windows` are on-screen layer-0 window bounds
    /// and `display` the display's bounds, both in the same coordinates
    /// (top-left origin). On a display with a camera notch, fullscreen
    /// windows start below it: `topInset` is that strip's height.
    public static func isFullscreen(windows: [CGRect], display: CGRect, topInset: CGFloat = 0) -> Bool {
        windows.contains { w in
            // Below the notch, give or take a point (Chrome sits 1 pt lower).
            let top = abs(w.minY - display.minY) < 1
                || (topInset > 0 && w.minY > display.minY && w.minY <= display.minY + topInset + 2)
            return top && abs(w.minX - display.minX) < 1 && abs(w.width - display.width) < 1
                && abs(w.maxY - display.maxY) < 1
        }
    }

    /// The thin strip at the bar's edge that reveals it.
    public static func triggerZone(screen: CGRect, bottom: Bool, thickness: CGFloat = 2) -> CGRect {
        bottom
            ? CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: thickness)
            : CGRect(x: screen.minX, y: screen.maxY - thickness, width: screen.width, height: thickness)
    }

    /// Where the pointer has to stay to keep a revealed bar: the bar plus
    /// some slack, so moving onto a pill doesn't hide it.
    public static func keepZone(screen: CGRect, bottom: Bool, height: CGFloat, slack: CGFloat = 12) -> CGRect {
        bottom
            ? CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: height + slack)
            : CGRect(x: screen.minX, y: screen.maxY - height - slack, width: screen.width, height: height + slack)
    }
}
