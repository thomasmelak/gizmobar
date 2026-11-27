import SwiftUI
import GizmoCore
import GizmoScene

/// The live audio visualizer for one source. Draws in its own Metal layer
/// straight from `AudioFrameHub`, so audio never re-renders SwiftUI; this
/// view only updates when the source, play state or colors change. Clipped
/// to `cornerRadius` so it stays inside the shape it sits in.
struct AudioVisualizer: View {
    let source: String?
    let playing: Bool
    /// One to three hex colors (album art, or the theme accent).
    let colors: [String]
    var placement: VisualizerPlacement = .popup
    var opacity: Double = 1
    var cornerRadius: CGFloat = 0
    @Environment(BarStore.self) private var store

    var body: some View {
        let media = store.config.media
        let style: VisualizerStyle = media.visualizer == .off ? .off : (placement == .row ? .bars : media.visualizer)
        VisualizerRepresentable(config: VisualizerConfig(
            source: media.spectrum ? source : nil, playing: playing, style: style, placement: placement,
            colors: colors, opacity: Float(opacity), bars: placement == .row ? 12 : media.bands
        ))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

private struct VisualizerRepresentable: NSViewRepresentable {
    let config: VisualizerConfig

    func makeNSView(context: Context) -> VisualizerView { VisualizerView(config: config) }
    func updateNSView(_ v: VisualizerView, context: Context) { v.apply(config) }
}
