import Foundation

/// How much you use each app, so `gizmo icons missing` can list the icons
/// worth drawing first. Counts activations and time in front; kept in
/// `~/Library/Application Support/Gizmobar/usage.json`, never sent anywhere.
public struct AppUsage: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var name: String
        public var activations: Int
        /// Seconds frontmost.
        public var seconds: Double
        public var lastUsed: Date

        public init(name: String, activations: Int = 0, seconds: Double = 0, lastUsed: Date) {
            self.name = name
            self.activations = activations
            self.seconds = seconds
            self.lastUsed = lastUsed
        }
    }

    public var apps: [String: Entry]
    /// The app in front and since when, to credit its time on the next switch.
    public var current: String?
    public var since: Date?

    public init(apps: [String: Entry] = [:]) { self.apps = apps }

    /// Records `bundleID` coming to the front at `date`, crediting the
    /// previous app with its time. Gaps over `maxSession` (sleep, a locked
    /// screen) count as `maxSession`.
    public mutating func activate(_ bundleID: String, name: String, at date: Date = Date(), maxSession: Double = 3600) {
        credit(until: date, maxSession: maxSession)
        var e = apps[bundleID] ?? Entry(name: name, lastUsed: date)
        e.name = name
        e.activations += 1
        e.lastUsed = date
        apps[bundleID] = e
        current = bundleID
        since = date
    }

    /// Credits the app in front up to `date` (used before saving).
    public mutating func credit(until date: Date = Date(), maxSession: Double = 3600) {
        guard let current, let since, var e = apps[current] else { return }
        e.seconds += min(max(date.timeIntervalSince(since), 0), maxSession)
        e.lastUsed = date
        apps[current] = e
        self.since = date
    }

    /// Most used first: time in front, then activations.
    public var ranked: [(bundleID: String, entry: Entry)] {
        apps.map { ($0.key, $0.value) }.sorted {
            $0.entry.seconds != $1.entry.seconds ? $0.entry.seconds > $1.entry.seconds : $0.entry.activations > $1.entry.activations
        }
    }

    public static func load(from url: URL = GizmoPaths.usageFile) -> AppUsage {
        guard let data = try? Data(contentsOf: url) else { return AppUsage() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var u = (try? dec.decode(AppUsage.self, from: data)) ?? AppUsage()
        u.current = nil
        u.since = nil
        return u
    }

    public func save(to url: URL = GizmoPaths.usageFile) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
