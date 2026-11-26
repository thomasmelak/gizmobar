import Foundation

/// Fan-out bus with "latest wins per (topic, key)" coalescing.
///
/// Publishers never wait on subscribers. Events published within one flush
/// window (default ~one frame) are collapsed, so a burst of 20 window events
/// during a workspace switch reaches the UI as one update.
public actor EventBus {
    public typealias Filter = @Sendable (String) -> Bool

    private struct Subscriber {
        let filter: Filter
        let continuation: AsyncStream<BarEvent>.Continuation
    }

    private struct Slot: Hashable {
        let topic: String
        let key: String?
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var pending: [Slot: BarEvent] = [:]
    private var order: [Slot] = []
    private var flushScheduled = false
    private let window: Duration

    public init(flushWindow: Duration = .milliseconds(16)) {
        self.window = flushWindow
    }

    /// Subscribe to topics matching `prefixes` (empty means everything).
    public func subscribe(prefixes: [String] = []) -> AsyncStream<BarEvent> {
        let id = UUID()
        let filter: Filter = { topic in
            prefixes.isEmpty || prefixes.contains { topic == $0 || topic.hasPrefix($0 + ".") }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: BarEvent.self, bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = Subscriber(filter: filter, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    public var subscriberCount: Int { subscribers.count }

    public func publish(_ event: BarEvent) {
        let slot = Slot(topic: event.topic, key: event.key)
        if pending.updateValue(event, forKey: slot) == nil { order.append(slot) }
        guard !flushScheduled else { return }
        flushScheduled = true
        let window = self.window
        Task {
            try? await Task.sleep(for: window)
            self.flush()
        }
    }

    public func publish(topic: String, key: String? = nil, payload: JSONValue = .null) {
        publish(BarEvent(topic: topic, key: key, payload: payload))
    }

    /// Deliver everything pending now. Exposed for tests.
    public func flush() {
        let events = order.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        flushScheduled = false
        for event in events {
            for sub in subscribers.values where sub.filter(event.topic) {
                sub.continuation.yield(event)
            }
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
