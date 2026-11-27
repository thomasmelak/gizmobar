import SwiftUI
import GizmoCore

struct BarView: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let layout = store.config.layout
        let bar = store.config.bar
        BarSections(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(layout.left, id: \.self) { WidgetRegistry.view(for: $0) }
            }
            HStack(spacing: 6) {
                ForEach(layout.center, id: \.self) { WidgetRegistry.view(for: $0) }
            }
            HStack(spacing: 6) {
                ForEach(layout.right, id: \.self) { WidgetRegistry.view(for: $0) }
            }
        }
        .padding(.horizontal, bar.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bar itself is transparent; each pill carries its own glass.
    }
}

/// Left, center and right sections. The center section sits on the bar's
/// midline when it fits, and otherwise slides into the free gap between the
/// left and right sections instead of overlapping them.
struct BarSections: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width } + spacing * 2
        let height = proposal.height ?? sizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let height = ProposedViewSize(width: nil, height: bounds.height)
        let left = subviews[0].sizeThatFits(height)
        let right = subviews[2].sizeThatFits(height)
        let y = bounds.midY

        subviews[0].place(at: CGPoint(x: bounds.minX, y: y), anchor: .leading, proposal: height)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: y), anchor: .trailing, proposal: height)

        // The free gap between the sections; the center group may shrink to it.
        let gapMin = bounds.minX + left.width + (left.width > 0 ? spacing : 0)
        let gapMax = bounds.maxX - right.width - (right.width > 0 ? spacing : 0)
        let gap = max(0, gapMax - gapMin)
        let center = subviews[1].sizeThatFits(ProposedViewSize(width: gap, height: bounds.height))
        let width = min(center.width, gap)
        let x = min(max(bounds.midX - width / 2, gapMin), gapMax - width)
        subviews[1].place(at: CGPoint(x: x, y: y), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}
