import SwiftUI
import GizmoCore

struct BarView: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let layout = store.config.layout
        let bar = store.config.bar
        ZStack {
            HStack(spacing: 6) {
                ForEach(layout.left, id: \.self) { WidgetRegistry.view(for: $0) }
                Spacer(minLength: 0)
                ForEach(layout.right, id: \.self) { WidgetRegistry.view(for: $0) }
            }
            HStack(spacing: 6) {
                ForEach(layout.center, id: \.self) { WidgetRegistry.view(for: $0) }
            }
        }
        .padding(.horizontal, bar.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GlassBackground(cornerRadius: 0, enabled: bar.glass)
        )
    }
}
