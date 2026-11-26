import CoreServices
import Foundation

/// Watches `~/.config/gizmobar` recursively with FSEvents and reports which
/// kind of file changed, debounced. Adding or editing an SVG in your custom
/// pack, a theme, or config.toml applies right away with no `gizmo reload`.
@MainActor
final class ConfigWatcher {
    enum Change: Hashable { case config, theme, iconPacks, plugins }

    private var stream: FSEventStreamRef?
    private var pending = Set<Change>()
    private var debounce: Task<Void, Never>?
    private let root: URL
    private let onChange: @MainActor (Set<Change>) -> Void

    init(root: URL, onChange: @escaping @MainActor (Set<Change>) -> Void) {
        self.root = root.resolvingSymlinksInPath()
        self.onChange = onChange
    }

    func start() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let changed = Array(list.prefix(count))
            MainActor.assumeIsolated { watcher.received(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        for path in paths {
            let rel = path.replacingOccurrences(of: root.path + "/", with: "")
            if rel == "config.toml" { pending.insert(.config) }
            else if rel.hasPrefix("themes/") { pending.insert(.theme) }
            else if rel.hasPrefix("icon-packs/") { pending.insert(.iconPacks) }
            else if rel.hasPrefix("plugins/") { pending.insert(.plugins) }
        }
        guard !pending.isEmpty else { return }
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let changes = self.pending
            self.pending.removeAll()
            self.onChange(changes)
        }
    }
}
