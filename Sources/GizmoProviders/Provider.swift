import Foundation
import GizmoCore

/// A data source that publishes to the bus. Providers read macOS APIs
/// in-process; nothing here runs on the render path.
public protocol Provider: Sendable {
    var id: String { get }
    func start(bus: EventBus) async
    func stop() async
}

/// Runs a command once and returns its stdout. Used only for one-off
/// snapshots and user actions, never per frame.
enum Command {
    static func run(_ executable: String, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return cont.resume(throwing: error) }
                // Drain before waiting so a large output can't fill the pipe and stall.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { cont.resume(returning: data) }
                else { cont.resume(throwing: CommandError.failed(executable, p.terminationStatus)) }
            }
        }
    }

    static func which(_ name: String, candidates: [String]) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in candidates + path {
            let full = dir.hasSuffix(name) ? dir : (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}

enum CommandError: Error {
    case failed(String, Int32)
}
