import Foundation

/// The persisted, user-editable part of a VM (docs/02 "User-editable
/// settings"). Everything else in the QEMU command line is fixed by
/// `QEMUCommand`.
///
/// Stored as `vms/<name>/config.json`.
public struct VMConfig: Codable, Sendable, Equatable {
    public var name: String
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskSizeGiB: Int
    public var graphicsBackend: GraphicsBackend
    public var network: NetworkMode
    public var portForwards: [PortForward]
    /// Stable MAC so Windows does not see a new NIC on every boot.
    public var macAddress: String
    /// Boot order and firmware-level devices.
    public var boot: BootSettings
    /// Removable media that stay attached across starts (an installer ISO,
    /// guest tools). Per-launch extras go in `LaunchOptions.removableDrives`.
    public var media: [AttachedMedia]

    public init(
        name: String = "default",
        cpuCount: Int = HostInfo.current.defaultVCPUs,
        memoryMiB: Int = HostInfo.current.defaultMemoryMiB,
        diskSizeGiB: Int = 64,
        graphicsBackend: GraphicsBackend = .dxmt,
        network: NetworkMode = .user,
        portForwards: [PortForward] = [],
        macAddress: String = VMConfig.randomMAC(),
        boot: BootSettings = BootSettings(),
        media: [AttachedMedia] = []
    ) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.diskSizeGiB = diskSizeGiB
        self.graphicsBackend = graphicsBackend
        self.network = network
        self.portForwards = portForwards
        self.macAddress = macAddress
        self.boot = boot
        self.media = media
    }

    private enum CodingKeys: String, CodingKey {
        case name, cpuCount, memoryMiB, diskSizeGiB, graphicsBackend, network, portForwards, macAddress, boot, media
    }

    /// Fields added after the first release decode with defaults, so older
    /// `config.json` files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryMiB = try c.decode(Int.self, forKey: .memoryMiB)
        diskSizeGiB = try c.decode(Int.self, forKey: .diskSizeGiB)
        graphicsBackend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend) ?? .dxmt
        network = try c.decodeIfPresent(NetworkMode.self, forKey: .network) ?? .user
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        macAddress = try c.decode(String.self, forKey: .macAddress)
        boot = try c.decodeIfPresent(BootSettings.self, forKey: .boot) ?? BootSettings()
        media = try c.decodeIfPresent([AttachedMedia].self, forKey: .media) ?? []
    }

    /// Firmware-level settings: what the UEFI firmware tries first and which
    /// platform devices exist.
    public struct BootSettings: Codable, Sendable, Equatable {
        public enum Order: String, Codable, Sendable, CaseIterable {
            /// System disk, then removable media. Normal use.
            case diskFirst = "disk-first"
            /// Removable media first: reinstalling, recovery media.
            case removableFirst = "removable-first"
        }

        public var order: Order
        /// TPM 2.0 (swtpm). Windows 11 Setup requires it; off only for
        /// troubleshooting.
        public var tpm: Bool
        /// Seconds the firmware waits for a key before booting (QEMU
        /// `-boot menu=on,splash-time`). 0 boots straight away.
        public var firmwareTimeoutSeconds: Int

        public init(order: Order = .diskFirst, tpm: Bool = true, firmwareTimeoutSeconds: Int = 0) {
            self.order = order
            self.tpm = tpm
            self.firmwareTimeoutSeconds = firmwareTimeoutSeconds
        }

        private enum CodingKeys: String, CodingKey { case order, tpm, firmwareTimeoutSeconds }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = try c.decodeIfPresent(Order.self, forKey: .order) ?? .diskFirst
            tpm = try c.decodeIfPresent(Bool.self, forKey: .tpm) ?? true
            firmwareTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .firmwareTimeoutSeconds) ?? 0
        }
    }

    /// A file attached as a USB drive (docs/02: removable media are USB
    /// mass storage).
    public struct AttachedMedia: Codable, Sendable, Equatable, Hashable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            /// Read-only CD-ROM (ISO).
            case cdrom
            /// Read-write raw disk image.
            case disk
        }

        public var path: String
        public var kind: Kind

        public init(path: String, kind: Kind = .cdrom) {
            self.path = path
            self.kind = kind
        }

        public var url: URL { URL(filePath: path) }
        public var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    /// Host-side D3D implementation used by virglrenderer's Neptune backend.
    /// Selected per launch through `NPT_BACKEND` (docs/04).
    public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
        /// Bundled, open source, native arm64. Default.
        case dxmt
        /// Apple's D3DMetal: optional, user-supplied, x86_64 under Rosetta.
        /// Needs a universal render server (not built by default, S1).
        case d3dmetal
    }

    public enum NetworkMode: String, Codable, Sendable {
        /// QEMU user networking (slirp). Default (docs/02, R11).
        case user
        /// vmnet shared mode. Needs root or the vmnet entitlement.
        case vmnetShared = "vmnet-shared"
        /// No network (image builds, docs/03).
        case none
    }

    public struct PortForward: Codable, Sendable, Equatable {
        public enum Proto: String, Codable, Sendable { case tcp, udp }
        public var proto: Proto
        public var hostPort: UInt16
        public var guestPort: UInt16

        public init(proto: Proto = .tcp, hostPort: UInt16, guestPort: UInt16) {
            self.proto = proto
            self.hostPort = hostPort
            self.guestPort = guestPort
        }
    }

    /// Locally administered unicast MAC (02:xx:xx:xx:xx:xx).
    public static func randomMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Problems that would make QEMU fail or misbehave. Empty when valid.
    public func validationErrors(host: HostInfo = .current) -> [String] {
        var errors: [String] = []
        if name.isEmpty || name.contains("/") || name.hasPrefix(".") || name.contains(",")
            || name.contains(where: \.isNewline) || name.count > 64 {
            errors.append("name must be a plain directory name (no '/', ',' or leading '.', at most 64 characters)")
        }
        if cpuCount < 1 || cpuCount > host.logicalCores {
            errors.append("cpuCount must be between 1 and \(host.logicalCores)")
        }
        if memoryMiB < 4096 {
            errors.append("memoryMiB must be at least 4096 (Windows 11 minimum)")
        }
        if memoryMiB > host.memoryMiB - 2048 {
            errors.append("memoryMiB must leave at least 2048 MiB for macOS")
        }
        if diskSizeGiB < 32 {
            errors.append("diskSizeGiB must be at least 32")
        }
        let macPattern = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/
        if macAddress.wholeMatch(of: macPattern) == nil {
            errors.append("macAddress must be six lowercase hex pairs")
        }
        let hostPorts = portForwards.map { "\($0.proto)/\($0.hostPort)" }
        if Set(hostPorts).count != hostPorts.count {
            errors.append("portForwards has a duplicate host port")
        }
        if portForwards.contains(where: { $0.hostPort == 0 || $0.guestPort == 0 }) {
            errors.append("portForwards ports must be 1-65535")
        }
        if !(0...30).contains(boot.firmwareTimeoutSeconds) {
            errors.append("boot.firmwareTimeoutSeconds must be between 0 and 30")
        }
        if Set(media.map(\.path)).count != media.count {
            errors.append("media lists the same file twice")
        }
        if media.contains(where: { !$0.path.hasPrefix("/") }) {
            errors.append("media paths must be absolute")
        }
        return errors
    }
}

/// Facts about this Mac used for defaults and validation.
public struct HostInfo: Sendable, Equatable {
    public var performanceCores: Int
    public var logicalCores: Int
    public var memoryMiB: Int

    public init(performanceCores: Int, logicalCores: Int, memoryMiB: Int) {
        self.performanceCores = performanceCores
        self.logicalCores = logicalCores
        self.memoryMiB = memoryMiB
    }

    public static let current: HostInfo = {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }
        let logical = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        return HostInfo(
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? logical,
            logicalCores: logical,
            memoryMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        )
    }()

    /// docs/02: performance-core count, capped at 8.
    public var defaultVCPUs: Int { min(performanceCores, 8) }

    /// docs/02: min(8 GiB, half of host), floor 4 GiB.
    public var defaultMemoryMiB: Int { max(4096, min(8192, memoryMiB / 2)) }
}
