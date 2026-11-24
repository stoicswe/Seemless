import Darwin
import Foundation

/// The line protocol between `seemlessctl mock-agent` and the Zen stand-in
/// helper (`proto/mock/zen-guest-helper.ps1`), a PowerShell script in the
/// guest that reports real window rectangles and applies size and window
/// commands until the Windows agent exists (WP4.2). Test tooling only: it
/// runs over the VM's user-mode network (the guest reaches the Mac's
/// loopback as 10.0.2.2), not the agent channel.
///
/// Guest → host, one per line (ASCII, space-separated, `\n`):
/// - `rect <id> <x> <y> <width> <height> <normal|min|max>`: the window's
///   visible frame (`DWMWA_EXTENDED_FRAME_BOUNDS`) and show state;
/// - `title <id> <text>`;
/// - `gone <id>`.
///
/// Host → guest: `set <id> <x> <y> <width> <height>` and
/// `cmd <id> <close|min|max|restore>`.
///
/// The guest is untrusted: lines are capped, numbers range-checked, and
/// anything malformed is dropped.
public enum GuestHelperMessage: Sendable, Equatable {
    case window(id: UInt64, rect: GuestRect, state: Seemless_V1_WindowShowState)
    case title(id: UInt64, String)
    case gone(UInt64)

    public static let maxLineLength = 1024

    public static func parse(_ line: String) -> GuestHelperMessage? {
        guard line.utf8.count <= maxLineLength else { return nil }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let id = UInt64(parts[1]), id != 0 else { return nil }
        switch parts[0] {
        case "rect":
            let f = trimmed.split(separator: " ")
            guard f.count == 7 else { return nil }
            let m = ZenWindowModel.maxCoordinate
            let n = f[2...5].compactMap { Int($0) }
            guard n.count == 4, n.allSatisfy({ abs($0) <= m }), n[2] >= 0, n[3] >= 0 else { return nil }
            let state: Seemless_V1_WindowShowState
            switch f[6] {
            case "normal": state = .normal
            case "min": state = .minimized
            case "max": state = .maximized
            default: return nil
            }
            return .window(id: id, rect: GuestRect(x: n[0], y: n[1], width: n[2], height: n[3]), state: state)
        case "title":
            return .title(id: id, parts.count > 2 ? String(parts[2]) : "")
        case "gone":
            return parts.count == 2 ? .gone(id) : nil
        default:
            return nil
        }
    }

    public static func setLine(id: UInt64, rect r: Seemless_V1_Rect) -> String {
        "set \(id) \(r.x) \(r.y) \(r.width) \(r.height)\n"
    }

    public static func commandLine(id: UInt64, _ cmd: Seemless_V1_WindowCommand.Command) -> String? {
        let word: String
        switch cmd {
        case .close: word = "close"
        case .minimize: word = "min"
        case .maximize: word = "max"
        case .restore: word = "restore"
        default: return nil
        }
        return "cmd \(id) \(word)\n"
    }
}

/// The window list the helper has reported, turned into agent messages.
public struct GuestHelperWindows: Sendable {
    public private(set) var windows: [UInt64: Seemless_V1_Window] = [:]
    public private(set) var order: [UInt64] = []

    public init() {}

    /// Applies one helper message; returns the agent event to send, if any.
    public mutating func apply(_ m: GuestHelperMessage) -> Seemless_V1_Envelope.OneOf_Body? {
        switch m {
        case .window(let id, let rect, let state):
            if var w = windows[id] {
                w.rect = rect.protoRect
                w.state = state
                windows[id] = w
                return .windowUpdated(.with { $0.window = w; $0.changed = [.rect, .state] })
            }
            guard windows.count < ZenWindowModel.maxWindows else { return nil }
            let w = Seemless_V1_Window.with {
                $0.id = id
                $0.kind = .normal
                $0.rect = rect.protoRect
                $0.state = state
                $0.appKey = "helper"
                $0.flags = .with { $0.resizable = true }
            }
            windows[id] = w
            order.append(id)
            return .windowAdded(.with { $0.window = w })
        case .title(let id, let text):
            guard var w = windows[id] else { return nil }
            w.title = text
            windows[id] = w
            return .windowUpdated(.with { $0.window = w; $0.changed = [.title] })
        case .gone(let id):
            guard windows.removeValue(forKey: id) != nil else { return nil }
            order.removeAll { $0 == id }
            return .windowRemoved(.with { $0.id = id })
        }
    }

    public var snapshot: Seemless_V1_Envelope.OneOf_Body {
        .windowSnapshot(.with { $0.windows = order.compactMap { windows[$0] } })
    }
}

/// A loopback TCP listener for the helper (the guest's 10.0.2.2:port).
enum LoopbackTCP {
    static func listen(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.Failure.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw UnixSocket.Failure.system("bind 127.0.0.1:\(port)", e) }
        guard Darwin.listen(fd, 2) == 0 else { let e = errno; close(fd); throw UnixSocket.Failure.system("listen", e) }
        return fd
    }
}
