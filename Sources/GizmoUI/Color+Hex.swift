import SwiftUI
import GizmoCore

extension Color {
    init(hex: String?, fallback: Color = .white) {
        guard let hex, let c = RGBA(hex: hex) else { self = fallback; return }
        self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
