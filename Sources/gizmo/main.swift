import Foundation
import GizmoCore
import GizmoIPC

let version = "0.1.0-dev"

let usage = """
gizmo: control Gizmobar

USAGE
  gizmo ping                      check that the bar is running
  gizmo trigger <topic> [k=v ...] push an event onto the bar's bus
  gizmo reload                    reload config, theme and icon packs
  gizmo state                     print what the bar currently shows
  gizmo icons missing             open apps the icon packs don't cover
  gizmo version

Plugin scaffolding (gizmo new) and the debug overlay (gizmo debug)
arrive with the plugin SDK.
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
case "ping":
    print(send(.init(command: "ping")).message ?? "")
case "trigger":
    guard let topic = args.first else { fail("usage: gizmo trigger <topic> [k=v ...]") }
    let r = send(.init(command: "trigger", args: [topic], payload: payload(from: args.dropFirst())))
    if !r.ok { fail(r.message ?? "failed") }
case "reload", "state", "icons":
    let r = send(.init(command: command, args: args))
    if !r.ok { fail(r.message ?? "failed") }
    if let data = r.data { printJSON(data) } else if let m = r.message { print(m) }
case "new", "debug":
    fail("gizmo \(command): not available yet (plugin SDK, Phase 4)")
default:
    fail("gizmo: unknown command '\(command)'\n\n\(usage)")
}
