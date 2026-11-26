import Foundation
import GizmoCore
#if canImport(Darwin)
import Darwin
#endif

public enum IPCClient {
    public static func send(_ request: IPCRequest, path: String = GizmoPaths.socket.path) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        var addr = try UnixSocket.address(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw IPCError.notRunning(path) }
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        UnixSocket.writeAll(fd, data)
        let reply = UnixSocket.readLine(fd)
        guard let response = try? JSONDecoder().decode(IPCResponse.self, from: reply) else { throw IPCError.badReply }
        return response
    }
}
