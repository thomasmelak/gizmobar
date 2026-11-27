import Foundation

// Placeholder for the shared audio frame hub (raw PCM per source, kept out
// of the event bus). The visualizer work replaces this file.
public final class AudioFrameHub: @unchecked Sendable {
    public static let shared = AudioFrameHub()

    /// Mono PCM for `source` (a bundle ID, or "system"); any thread.
    public func write(source: String, samples: UnsafeBufferPointer<Float>, sampleRate: Double) {}
}
