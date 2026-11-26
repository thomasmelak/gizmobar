import Foundation
import GizmoCore

/// Publishes `clock.tick` on each second boundary. No process, no polling drift.
public actor ClockProvider: Provider {
    public nonisolated let id = "clock"
    private var task: Task<Void, Never>?

    public init() {}

    public func start(bus: EventBus) async {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                await bus.publish(topic: Topic.clockTick, payload: ["epoch": .number(now.rounded(.down))])
                let wait = 1 - (now - now.rounded(.down))
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(50))
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
    }
}
