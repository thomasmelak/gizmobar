import Foundation

/// Puts `gizmo` on the PATH for installs that don't (the DMG): links
/// ~/.local/bin/gizmo to the copy inside this app, unless Homebrew, the
/// installer or `make install` already put one there.
enum CLILink {
    static func ensure() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let fm = FileManager.default
        let target = bundle.appendingPathComponent("Contents/MacOS/gizmo")
        guard fm.isExecutableFile(atPath: target.path) else { return }
        let link = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gizmo")
        for path in ["/opt/homebrew/bin/gizmo", "/usr/local/bin/gizmo", link.path] {
            if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { return }
        }
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            NSLog("gizmobar: linking gizmo: \(error)")
        }
    }
}
