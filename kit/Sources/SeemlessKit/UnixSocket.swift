import Darwin
import Foundation

/// Minimal blocking unix-domain stream socket helpers.
public enum UnixSocket {
    public enum Failure: Error, CustomStringConvertible {
        case pathTooLong(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path too long (>\(StorageLayout.maxSocketPathBytes) bytes): \(p)"
            case .system(let call, let err): return "\(call): \(String(cString: strerror(err)))"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= StorageLayout.maxSocketPathBytes else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Connects to a listening socket. Returns the file descriptor.
    public static func connect(path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = try makeSocket()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            close(fd)
            throw Failure.system("connect \(path)", err)
        }
        return fd
    }

    /// Retries `connect` until it succeeds or `timeout` passes. Used while a
    /// child process is still creating its socket.
    public static func connect(path: String, timeout: Duration) async throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        while true {
            do { return try connect(path: path) } catch {
                if ContinuousClock.now >= deadline { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Creates a listening socket (tests and the mock agent). Removes a stale
    /// socket file first.
    public static func listen(path: String, backlog: Int32 = 4) throws -> Int32 {
        unlink(path)
        var addr = try address(path)
        let fd = try makeSocket()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { let e = errno; close(fd); throw Failure.system("bind \(path)", e) }
        guard Darwin.listen(fd, backlog) == 0 else { let e = errno; close(fd); throw Failure.system("listen", e) }
        return fd
    }
}
