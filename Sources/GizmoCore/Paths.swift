import Foundation

public enum GizmoPaths {
    /// `~/.config/gizmobar`, or `$GIZMOBAR_CONFIG_DIR` when set.
    public static var configDir: URL {
        if let override = ProcessInfo.processInfo.environment["GIZMOBAR_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("gizmobar", isDirectory: true)
    }

    public static var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public static var themesDir: URL { configDir.appendingPathComponent("themes", isDirectory: true) }
    public static var pluginsDir: URL { configDir.appendingPathComponent("plugins", isDirectory: true) }
    public static var iconPacksDir: URL { configDir.appendingPathComponent("icon-packs", isDirectory: true) }

    /// Control socket used by the `gizmo` CLI.
    public static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["GIZMOBAR_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gizmobar-\(getuid()).sock")
    }

    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
