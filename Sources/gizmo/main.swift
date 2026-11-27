import Foundation
import GizmoCore
import GizmoIPC

/// The app bundle this binary ships in (Gizmobar.app/Contents/MacOS/gizmo),
/// following the symlink Homebrew or `make install` puts on the PATH.
let appContents: URL? = {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
    return contents.lastPathComponent == "Contents" ? contents : nil
}()

let version: String = {
    guard let plist = appContents?.appendingPathComponent("Info.plist"),
          let dict = NSDictionary(contentsOf: plist),
          let v = dict["CFBundleShortVersionString"] as? String else { return "0.1.0-dev" }
    return v
}()

/// Copies the bundled example config into the config dir, never overwriting.
func initConfig() {
    guard let source = appContents?.appendingPathComponent("Resources/examples/gizmobar", isDirectory: true),
          FileManager.default.fileExists(atPath: source.path) else {
        fail("gizmo: no bundled example config found; from a source checkout run `make config`")
    }
    let fm = FileManager.default
    let dest = GizmoPaths.configDir
    var copied = 0, kept = 0
    do {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for rel in try fm.subpathsOfDirectory(atPath: source.path).sorted() {
            let item = source.appendingPathComponent(rel)
            let target = dest.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if fm.fileExists(atPath: target.path) {
                kept += 1
            } else {
                try fm.copyItem(at: item, to: target)
                copied += 1
            }
        }
    } catch { fail("gizmo: \(error)") }
    print("\(dest.path): copied \(copied) files, kept \(kept) existing")
}

let usage = """
gizmo: control Gizmobar

USAGE
  gizmo ping                      check that the bar is running
  gizmo trigger <topic> [k=v ...] push an event onto the bar's bus
  gizmo reload                    reload config, theme and icon packs
  gizmo state                     print what the bar currently shows
  gizmo icons missing             apps the icon packs don't cover, most used first
  gizmo icons init <id>           start a custom icon pack in ~/.config/gizmobar/icon-packs
  gizmo new <id>                  scaffold a TypeScript plugin in ~/.config/gizmobar/plugins
  gizmo types [--sdk]             print the @gizmobar/sdk declarations (--sdk: sdk/src/providers.ts)
  gizmo debug                     plugin render times, budget overruns and provider update counts
  gizmo plugins reload|log|resume <id>
  gizmo config init               copy the example config into ~/.config/gizmobar (never overwrites)
  gizmo version
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func send(_ req: IPCRequest) -> IPCResponse {
    do { return try IPCClient.send(req) } catch { fail("gizmo: \(error)") }
}

func printJSON(_ value: JSONValue) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

/// `k=v` pairs become a JSON object; numbers and booleans are typed.
func payload(from pairs: ArraySlice<String>) -> JSONValue {
    var obj: [String: JSONValue] = [:]
    for pair in pairs {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("gizmo: expected k=v, got \(pair)") }
        let v = parts[1]
        if let n = Double(v) { obj[parts[0]] = .number(n) }
        else if v == "true" || v == "false" { obj[parts[0]] = .bool(v == "true") }
        else { obj[parts[0]] = .string(v) }
    }
    return .object(obj)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "help", "-h", "--help":
    print(usage)
case "version", "--version":
    print(version)
case "config" where args.first == "init":
    initConfig()
case "ping":
    print(send(.init(command: "ping")).message ?? "")
case "trigger":
    guard let topic = args.first else { fail("usage: gizmo trigger <topic> [k=v ...]") }
    let r = send(.init(command: "trigger", args: [topic], payload: payload(from: args.dropFirst())))
    if !r.ok { fail(r.message ?? "failed") }
case "icons" where args.first == "init":
    guard args.count == 2 else { fail("usage: gizmo icons init <id>") }
    let dir = GizmoPaths.iconPacksDir.appendingPathComponent(args[1], isDirectory: true)
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.path) { fail("gizmo: \(dir.path) already exists") }
    do {
        try fm.createDirectory(at: dir.appendingPathComponent("icons"), withIntermediateDirectories: true)
        let manifest = IconPack.Manifest(id: args[1], name: args[1], kind: .svg, grid: 24, stroke: 1.5)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("pack.json"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("colors.json"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("aliases.json"))
    } catch { fail("gizmo: \(error)") }
    print("""
    created \(dir.path)
    Drop <bundle-id>.svg files (fill="currentColor") into icons/; the bar picks them up live.
    Use it with:  [icons] custom_pack = "\(args[1])"
    """)
case "reload", "state", "icons":
    let r = send(.init(command: command, args: args))
    if !r.ok { fail(r.message ?? "failed") }
    if let data = r.data { printJSON(data) } else if let m = r.message { print(m) }
case "new":
    guard args.count == 1, PluginScaffold.isValid(id: args[0]) else {
        fail("usage: gizmo new <id>   (lowercase letters, digits and dashes)")
    }
    let dir = GizmoPaths.pluginsDir.appendingPathComponent(args[0], isDirectory: true)
    if FileManager.default.fileExists(atPath: dir.path) { fail("gizmo: \(dir.path) already exists") }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in PluginScaffold.files(id: args[0]) {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    } catch { fail("gizmo: \(error)") }
    print("""
    created \(dir.path)

    1. Show it: add "\(args[0])" to a [layout] list in ~/.config/gizmobar/config.toml
    2. Build:   brew install esbuild   (the bar then rebuilds on every save)
                or: cd \(dir.path) && npm install && npm run build
    3. Edit index.ts; types are in gizmobar.d.ts
    """)
case "types":
    print(args.first == "--sdk" ? PluginProviders.typescriptModule : SDKTypes.declaration, terminator: "")
case "debug":
    let r = send(.init(command: "plugins"))
    if !r.ok { fail(r.message ?? "failed") }
    guard let data = r.data else { exit(0) }
    let list = data["plugins"]?.array ?? []
    if list.isEmpty { print("no plugins loaded (\(GizmoPaths.pluginsDir.path))") }
    func n(_ v: JSONValue?) -> String { if case .number(let d)? = v { return d == d.rounded() ? String(Int(d)) : String(d) }; return "-" }
    print("PLUGIN".padding(toLength: 20, withPad: " ", startingAt: 0) + "RENDERS  AVG ms  MAX ms  OVER  STATE")
    for p in list {
        let paused: Bool = { if case .bool(let b)? = p["paused"] { return b }; return false }()
        let state = p["error"]?.string.map { "error: \($0.prefix(60))" } ?? (paused ? "paused (gizmo plugins resume \(p["id"]?.string ?? ""))" : "ok")
        print((p["id"]?.string ?? "?").padding(toLength: 20, withPad: " ", startingAt: 0)
            + n(p["renders"]).padding(toLength: 9, withPad: " ", startingAt: 0)
            + n(p["avgMs"]).padding(toLength: 8, withPad: " ", startingAt: 0)
            + n(p["maxMs"]).padding(toLength: 8, withPad: " ", startingAt: 0)
            + n(p["overruns"]).padding(toLength: 6, withPad: " ", startingAt: 0) + state)
    }
    if case .object(let rates)? = data["providerUpdates"], !rates.isEmpty {
        print("\nPROVIDER UPDATES SINCE LAUNCH")
        for (k, v) in rates.sorted(by: { $0.key < $1.key }) { print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) \(n(v))") }
    }
case "plugins":
    let r = send(.init(command: "plugins", args: args.isEmpty ? ["log"] : args))
    if !r.ok { fail(r.message ?? "failed") }
    if let m = r.message { print(m) }
default:
    fail("gizmo: unknown command '\(command)'\n\n\(usage)")
}
