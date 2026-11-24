import Foundation

/// The Seemless guest tools (docs/06 "Guest tools ISO", WP4.3): the agent
/// folder the image build copies into every new VM, and `seemless-tools.iso`,
/// which updates the agent in a running VM.
///
/// Layout of a tools folder (built by `guest/tools/build.sh`):
///
///     agent/                 seemless-agent-svc.exe, seemless-agent.exe,
///                            install.cmd, uninstall.cmd, version.txt
///     seemless-tools.iso     volume SEEMLESS_TOOLS: install.cmd, version.txt,
///                            agent/, drivers/ (optional)
///
/// The tools version is the agent's Hello build without the binary name:
/// "seemless-agent-svc 0.0.2 (8bc3fb59e430)" → "0.0.2 (8bc3fb59e430)".
public struct GuestTools: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static let volumeLabel = "SEEMLESS_TOOLS"
    public static let isoName = "seemless-tools.iso"
    /// Largest `version.txt` read; the guest enforces the same bound.
    static let maxVersionFile = 256
    /// Longest version string sent in `UpdateTools` (the guest's limit).
    public static let maxVersionLength = 64

    public var agentDirectory: URL { root.appending(path: "agent", directoryHint: .isDirectory) }
    public var iso: URL { root.appending(path: Self.isoName) }

    public var hasAgent: Bool {
        ["seemless-agent-svc.exe", "seemless-agent.exe", "install.cmd"].allSatisfy {
            FileManager.default.isReadableFile(atPath: agentDirectory.appending(path: $0).path(percentEncoded: false))
        }
    }

    public var hasISO: Bool { FileManager.default.isReadableFile(atPath: iso.path(percentEncoded: false)) }

    /// `agent/version.txt`, trimmed; nil if missing or not a plausible version.
    public var version: String? {
        let url = agentDirectory.appending(path: "version.txt")
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
              data.count <= Self.maxVersionFile else { return nil }
        return Self.validVersion(String(decoding: data, as: UTF8.self))
    }

    /// The trimmed version if it is 1–64 printable ASCII characters.
    static func validVersion(_ text: String) -> String? {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.utf8.count <= maxVersionLength, v.utf8.allSatisfy({ (0x20..<0x7f).contains($0) }) else { return nil }
        return v
    }

    /// The tools version an agent reports in its Hello build string.
    public static func version(fromBuild build: String) -> String {
        guard let space = build.firstIndex(of: " ") else { return build }
        return String(build[build.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    /// `$SEEMLESS_GUEST_TOOLS`, else `Contents/Resources/guest-tools` of the
    /// app bundle running this code, else `build/guest-tools` in the
    /// repository containing the executable or the current directory. Only
    /// folders holding a built agent count.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: URL = URL(filePath: CommandLine.arguments.first ?? ""),
                              currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath,
                                                          directoryHint: .isDirectory)) -> GuestTools? {
        if let explicit = environment["SEEMLESS_GUEST_TOOLS"], !explicit.isEmpty {
            let t = GuestTools(root: URL(filePath: explicit, directoryHint: .isDirectory))
            return t.hasAgent ? t : nil
        }
        let exeDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = exeDir.deletingLastPathComponent()
        if contents.lastPathComponent == "Contents" {
            let bundled = GuestTools(root: contents.appending(path: "Resources/guest-tools", directoryHint: .isDirectory))
            if bundled.hasAgent { return bundled }
        }
        for start in [exeDir, currentDirectory] {
            var dir = start
            for _ in 0..<8 {
                let candidate = GuestTools(root: dir.appending(path: "build/guest-tools", directoryHint: .isDirectory))
                if candidate.hasAgent { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    // MARK: QMP

    /// Node and device ids of the hot-plugged tools CD (one per VM at a time).
    static let nodeName = "sltools"
    static let botID = "sltoolsbot"
    static let cdID = "sltoolsdev"

    /// Hot-plugs `iso` as a read-only USB CD-ROM (`usb-bot` + `scsi-cd`, then
    /// `attached`), so
    /// Windows mounts it as a CD with its volume label. A tools CD left over
    /// from an earlier update is removed first.
    static func attach(iso: URL, qmp: QMPClient) async throws {
        await detach(qmp: qmp)
        try await qmp.execute("blockdev-add", arguments: [
            "driver": "raw",
            "node-name": .string(nodeName),
            "read-only": true,
            "file": ["driver": "file", "filename": .string(iso.path(percentEncoded: false)), "read-only": true],
        ])
        do {
            try await qmp.execute("device_add", arguments: ["driver": "usb-bot", "id": .string(botID), "bus": "usb.0"])
            try await qmp.execute("device_add", arguments: [
                "driver": "scsi-cd", "id": .string(cdID), "bus": .string("\(botID).0"), "drive": .string(nodeName),
            ])
            // A hot-plugged usb-bot stays detached until its LUNs are added and
            // `attached` is set (QEMU docs/system/devices/usb.rst); without this
            // Windows never sees the CD (found on wp42, 2026-11-24).
            try await qmp.execute("qom-set", arguments: [
                "path": .string("/machine/peripheral/\(botID)"), "property": "attached", "value": true,
            ])
        } catch {
            await detach(qmp: qmp)
            throw error
        }
    }

    /// Unplugs the tools CD if present. Never throws: there may be nothing to remove.
    static func detach(qmp: QMPClient) async {
        _ = try? await qmp.execute("device_del", arguments: ["id": .string(botID)])
        // The block node can only go once the device is gone.
        for _ in 0..<30 {
            let nodes = (try? await qmp.execute("query-named-block-nodes", arguments: ["flat": true]))?.arrayValue ?? []
            guard nodes.contains(where: { $0["node-name"]?.stringValue == nodeName }) else { return }
            if (try? await qmp.execute("blockdev-del", arguments: ["node-name": .string(nodeName)])) != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
