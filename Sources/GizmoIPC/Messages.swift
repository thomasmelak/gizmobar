import Foundation
import GizmoCore

/// One request per connection, newline-terminated JSON in both directions.
public struct IPCRequest: Sendable, Codable, Equatable {
    public var command: String
    public var args: [String]
    public var payload: JSONValue

    public init(command: String, args: [String] = [], payload: JSONValue = .null) {
        self.command = command
        self.args = args
        self.payload = payload
    }
}

public struct IPCResponse: Sendable, Codable, Equatable {
    public var ok: Bool
    public var message: String?
    public var data: JSONValue?

    public init(ok: Bool, message: String? = nil, data: JSONValue? = nil) {
        self.ok = ok
        self.message = message
        self.data = data
    }

    public static func error(_ message: String) -> IPCResponse { .init(ok: false, message: message) }
}

public enum IPCError: Error, CustomStringConvertible {
    case socket(String)
    case notRunning(String)
    case badReply

    public var description: String {
        switch self {
        case .socket(let s): return "socket error: \(s)"
        case .notRunning(let p): return "Gizmobar isn't running (no socket at \(p))"
        case .badReply: return "unreadable reply from Gizmobar"
        }
    }
}
