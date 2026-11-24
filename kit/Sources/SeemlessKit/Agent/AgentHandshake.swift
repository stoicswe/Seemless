import Foundation

/// `Hello` validation and capability negotiation (docs/06 "Handshake"); the
/// same rules as `guest/agent/crates/proto/src/handshake.rs`.
public enum AgentHandshake {
    public static let protocolMajor: UInt32 = 1
    public static let protocolMinor: UInt32 = 0

    /// Limits on a peer's `Hello` (the guest is untrusted).
    public static let maxBuildBytes = 256
    public static let maxCapabilities = 64
    public static let maxCapabilityBytes = 64

    /// Capability strings: a message family and its version.
    public enum Capability {
        /// Hello, Ping/Pong, Error/Ack, GetGuestInfo/GuestInfo, SessionState.
        public static let core = "core.v1"
        public static let system = "system.v1"
        public static let windows = "windows.v1"
        public static let apps = "apps.v1"
        public static let clipboard = "clipboard.v1"
        public static let dragDrop = "dragdrop.v1"
    }

    public struct Negotiated: Sendable, Equatable {
        public var peerMajor: UInt32
        public var peerMinor: UInt32
        public var peerBuild: String
        public var peerRole: Seemless_V1_Role
        /// Capabilities both sides listed, sorted.
        public var capabilities: [String]

        public func has(_ capability: String) -> Bool { capabilities.contains(capability) }
    }

    public enum HandshakeError: Error, Equatable, CustomStringConvertible {
        case majorMismatch(local: UInt32, remote: UInt32)
        case wrongRole(Int)
        case invalid(String)

        public var description: String {
            switch self {
            case .majorMismatch(let l, let r): return "guest protocol \(r).x is not compatible with \(l).x; update the guest tools"
            case .wrongRole(let r): return "peer has the wrong role (\(r))"
            case .invalid(let why): return "invalid Hello: \(why)"
            }
        }
    }

    public static func hello(role: Seemless_V1_Role, build: String, capabilities: [String]) -> Seemless_V1_Hello {
        var h = Seemless_V1_Hello()
        h.protocolMajor = protocolMajor
        h.protocolMinor = protocolMinor
        h.build = build
        h.capabilities = capabilities
        h.role = role
        return h
    }

    static func isValidCapability(_ c: String) -> Bool {
        let bytes = Array(c.utf8)
        return !bytes.isEmpty && bytes.count <= maxCapabilityBytes && bytes.allSatisfy {
            (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    public static func negotiate(local: Seemless_V1_Hello, remote: Seemless_V1_Hello) throws(HandshakeError) -> Negotiated {
        guard remote.build.utf8.count <= maxBuildBytes else { throw .invalid("build string too long") }
        guard remote.capabilities.count <= maxCapabilities else { throw .invalid("too many capabilities") }
        if let bad = remote.capabilities.first(where: { !isValidCapability($0) }) {
            throw .invalid("bad capability \(String(reflecting: String(bad.prefix(80))))")
        }
        let expected: Seemless_V1_Role
        switch local.role {
        case .host: expected = .guestService
        case .guestService: expected = .host
        default: throw .invalid("local role unspecified")
        }
        // An unknown enum value decodes as .UNRECOGNIZED, which never matches.
        guard remote.role == expected else { throw .wrongRole(remote.role.rawValue) }
        guard remote.protocolMajor == local.protocolMajor else {
            throw .majorMismatch(local: local.protocolMajor, remote: remote.protocolMajor)
        }
        let shared = Set(local.capabilities).intersection(remote.capabilities).sorted()
        return Negotiated(peerMajor: remote.protocolMajor, peerMinor: remote.protocolMinor,
                          peerBuild: remote.build, peerRole: remote.role, capabilities: shared)
    }
}

public extension Seemless_V1_Envelope {
    init(seq: UInt64, replyTo: UInt64 = 0, body: OneOf_Body) {
        self.init()
        self.seq = seq
        self.replyTo = replyTo
        self.body = body
    }

    /// The body case's protobuf JSON name, e.g. "guestInfo" (for logs,
    /// scripts and errors). Empty for a body this build does not know.
    var bodyName: String {
        guard let body else { return "" }
        return Self.bodyName(body)
    }

    static func bodyName(_ body: OneOf_Body) -> String {
        // "hello(Seemless_V1_Hello(...))" -> "hello"
        let text = String(describing: body)
        return String(text.prefix { $0 != "(" })
    }
}
