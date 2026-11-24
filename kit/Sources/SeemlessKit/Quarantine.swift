import Foundation

/// A quarantined VM's connections to the Mac (owner, 2026-11-24; docs/07
/// "Quarantine"). Every connection starts off. Keyboard, mouse and display
/// are always on: they are how the user works in the VM.
///
/// "Off" means no device: the virtual hardware for that connection is left
/// out of the QEMU command line, so the guest cannot reach it at all, and a
/// change applies at the next start. Features built on the guest agent
/// (clipboard, file transfer) also need `agent` on, and must check
/// `VMConfig.allows(_:)` before moving any data (the guest is untrusted).
public struct Quarantine: Codable, Sendable, Equatable {
    /// Network card (internet). Off: no NIC, no port forwards.
    public var network: Bool
    /// Guest agent channel (virtio-serial). Needed for Zen mode, window
    /// information, clean shutdown, and the clipboard and file features.
    public var agent: Bool
    /// Clipboard, Mac → Windows (needs `agent`).
    public var clipboardToGuest: Bool
    /// Clipboard, Windows → Mac (needs `agent`).
    public var clipboardToHost: Bool
    /// Files: drag and drop, opening Mac files in Windows, shared folders
    /// (these need `agent`), and attaching USB disks or ISOs.
    public var files: Bool
    /// Sound out. (QEMU's `usb-audio` is playback only; there is no
    /// microphone device to switch yet.)
    public var audio: Bool

    public init(network: Bool = false, agent: Bool = false, clipboardToGuest: Bool = false,
                clipboardToHost: Bool = false, files: Bool = false, audio: Bool = false) {
        self.network = network
        self.agent = agent
        self.clipboardToGuest = clipboardToGuest
        self.clipboardToHost = clipboardToHost
        self.files = files
        self.audio = audio
    }

    /// Everything off: the state a new quarantined VM starts in.
    public static let isolated = Quarantine()

    private enum CodingKeys: String, CodingKey {
        case network, agent, clipboardToGuest, clipboardToHost, files, audio
    }

    /// Missing fields decode as off, so a connection added later is never
    /// switched on by accident in an older config.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
        agent = try c.decodeIfPresent(Bool.self, forKey: .agent) ?? false
        clipboardToGuest = try c.decodeIfPresent(Bool.self, forKey: .clipboardToGuest) ?? false
        clipboardToHost = try c.decodeIfPresent(Bool.self, forKey: .clipboardToHost) ?? false
        files = try c.decodeIfPresent(Bool.self, forKey: .files) ?? false
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? false
    }
}

extension VMConfig {
    /// A connection between the VM and the Mac that quarantine controls.
    public enum Connection: String, Sendable, CaseIterable {
        case network, agent, clipboardToGuest, clipboardToHost, files, audio
    }

    public var isQuarantined: Bool { quarantine != nil }

    /// Whether this VM may use a connection. A normal VM allows everything;
    /// a quarantined one only what is switched on, and the clipboard only
    /// with the agent channel present.
    public func allows(_ connection: Connection) -> Bool {
        guard let q = quarantine else { return true }
        switch connection {
        case .network: return q.network
        case .agent: return q.agent
        case .clipboardToGuest: return q.agent && q.clipboardToGuest
        case .clipboardToHost: return q.agent && q.clipboardToHost
        case .files: return q.files
        case .audio: return q.audio
        }
    }

    /// The network the VM actually gets: none when quarantine has it off.
    public var effectiveNetwork: NetworkMode { allows(.network) ? network : .none }
}
