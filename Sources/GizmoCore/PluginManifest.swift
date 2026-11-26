import Foundation

/// `plugins/<id>/plugin.json`. The runtime (JavaScriptCore, one context per
/// plugin) arrives in Phase 4; the manifest format is fixed now so example
/// plugins and the SDK can be written against it.
public struct PluginManifest: Sendable, Equatable, Codable {
    public var id: String
    public var name: String?
    public var version: String
    /// Compiled JS entry relative to the plugin folder, e.g. `dist/index.js`.
    public var entry: String
    /// `provider:<name>`, `net:<host>`, `exec`. Nothing is allowed without them.
    public var permissions: [String]

    public init(id: String, name: String? = nil, version: String, entry: String, permissions: [String] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.entry = entry
        self.permissions = permissions
    }

    public func allows(_ permission: String) -> Bool {
        permissions.contains(permission) || permissions.contains { p in
            p.hasSuffix(":*") && permission.hasPrefix(p.dropLast())
        }
    }
}
