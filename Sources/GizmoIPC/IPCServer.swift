import Foundation
import GizmoCore
#if canImport(Darwin)
import Darwin
#endif

/// Listens on the control socket for `gizmo` CLI requests. Accepting runs on
/// its own thread; each request is handled by an async handler, so a slow
/// command never blocks the bar.
public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private var thread: Thread?

    public init(path: String = GizmoPaths.socket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socket(String(cString: strerror(errno))) }
        var addr = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw IPCError.socket(String(cString: strerror(errno)))
        }
        chmod(path, 0o600)
        let listener = fd
        let handler = self.handler
        let t = Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Task.detached {
                    let line = UnixSocket.readLine(client)
                    let response: IPCResponse
                    if let req = try? JSONDecoder().decode(IPCRequest.self, from: line) {
                        response = await handler(req)
                    } else {
                        response = .error("bad request")
                    }
                    var out = (try? JSONEncoder().encode(response)) ?? Data()
                    out.append(0x0A)
                    UnixSocket.writeAll(client, out)
                    close(client)
                }
            }
        }
        t.name = "gizmobar.ipc"
        t.start()
        thread = t
    }

    public func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }
}
