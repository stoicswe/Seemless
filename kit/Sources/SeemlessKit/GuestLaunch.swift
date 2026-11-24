import Foundation

/// "Open in Seemless": runs a Windows installer from the Mac inside the VM
/// (docs/07 "Files").
///
/// Until the guest agent and shared folders exist (M4, S7), the file travels
/// on a small FAT32 USB drive labelled `SLRUN` that is hot-plugged into the
/// running VM over QMP. The Windows side (`image/guest/SeemlessLauncher.ps1`,
/// a logon task installed by the image build) copies the installer to %TEMP%
/// and starts it once per request id. VMs without the launcher still see the
/// drive in Explorer; it also carries "Enable automatic installs.cmd".
///
/// Host → guest only. The drive is read-only to the guest, so nothing the
/// guest does comes back to the Mac this way.
public enum GuestLaunch {
    public static let volumeLabel = "SLRUN"
    public static let requestFile = "seemless-launch.txt"
    public static let allowedExtensions: Set<String> = ["exe", "msi"]
    /// FAT32's largest file.
    public static let maxFileBytes: UInt64 = 0xFFFF_FFFF
    /// Node and device names start with this, so stale drives can be found
    /// from any controller (the CLI or the app) without shared state.
    static let nodePrefix = "sll"

    public struct Request: Sendable, Equatable {
        /// 32 lowercase hex characters, new for every request.
        public var id: String
        /// File name on the drive (and in Windows).
        public var fileName: String
        public var image: URL

        var shortID: String { String(id.prefix(8)) }
        var nodeName: String { "\(GuestLaunch.nodePrefix)\(shortID)" }
        var deviceID: String { "\(GuestLaunch.nodePrefix)dev\(shortID)" }
    }

    public enum LaunchError: Error, Equatable, CustomStringConvertible {
        case unsupportedType(String), notFound(String), tooLarge(String), notRunning(String)

        public var description: String {
            switch self {
            case .unsupportedType(let f): return "\(f) is not a Windows installer (.exe or .msi)"
            case .notFound(let f): return "not found: \(f)"
            case .tooLarge(let f): return "\(f) is larger than 4 GB, the most a FAT32 launch drive can hold"
            case .notRunning(let n): return "VM '\(n)' is not running; start it first"
            }
        }
    }

    public static func isSupported(_ url: URL) -> Bool { allowedExtensions.contains(url.pathExtension.lowercased()) }

    /// A name Windows accepts: reserved characters become "_", the extension
    /// is kept in lower case, at most 120 characters.
    public static func guestFileName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        var stem = url.deletingPathExtension().lastPathComponent
        let bad = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        stem = String(stem.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if stem.isEmpty { stem = "installer" }
        return String(stem.prefix(120)) + "." + ext
    }

    /// Builds the launch drive for `installer` in `directory`.
    public static func makeDrive(for installer: URL, in directory: URL, assets: ImageAssets? = nil) async throws -> Request {
        let path = installer.path(percentEncoded: false)
        guard isSupported(installer) else { throw LaunchError.unsupportedType(installer.lastPathComponent) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            throw LaunchError.notFound(path)
        }
        guard size <= maxFileBytes else { throw LaunchError.tooLarge(installer.lastPathComponent) }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let name = guestFileName(for: installer)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appending(path: "\(id.prefix(8)).img")
        // Room for FAT32 structures; 64 MiB is comfortably above its minimum.
        let sizeMiB = max(64, Int(size >> 20) + 48)
        try await FATImage.create(at: image, sizeMiB: sizeMiB, label: volumeLabel)
        do {
            try await FATImage.withMounted(image, readOnly: false) { root in
                try FileManager.default.copyItem(at: installer, to: root.appending(path: name))
                try Data("\(id)\r\n\(name)\r\n".utf8).write(to: root.appending(path: requestFile))
                try Data("""
                    Sent from the Mac with "Open in Seemless".\r
                    \r
                    If the installer did not start by itself, double-click \(name).\r
                    To make installers start by themselves from now on, run\r
                    "Enable automatic installs.cmd" once.\r

                    """.utf8).write(to: root.appending(path: "README.txt"))
                if let assets {
                    for script in ImageAssets.launcherScripts + [ImageAssets.enableLauncherScript] {
                        let source = assets.guest.appending(path: script)
                        guard let data = FileManager.default.contents(atPath: source.path(percentEncoded: false)) else { continue }
                        try crlf(data).write(to: root.appending(path: script))
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: image)
            throw error
        }
        return Request(id: id, fileName: name, image: image)
    }

    static func crlf(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    // MARK: QMP

    /// Hot-plugs the drive as a read-only USB disk.
    static func attach(_ request: Request, qmp: QMPClient) async throws {
        try await qmp.execute("blockdev-add", arguments: [
            "driver": "raw",
            "node-name": .string(request.nodeName),
            "read-only": true,
            "file": ["driver": "file", "filename": .string(request.image.path(percentEncoded: false)), "read-only": true],
        ])
        do {
            try await qmp.execute("device_add", arguments: [
                "driver": "usb-storage",
                "bus": "usb.0",
                "drive": .string(request.nodeName),
                "id": .string(request.deviceID),
                "removable": true,
            ])
        } catch {
            _ = try? await qmp.execute("blockdev-del", arguments: ["node-name": .string(request.nodeName)])
            throw error
        }
    }

    /// Launch drives currently plugged in, by node name.
    static func attachedNodes(qmp: QMPClient) async throws -> [String] {
        let nodes = try await qmp.execute("query-named-block-nodes", arguments: ["flat": true])
        return (nodes.arrayValue ?? []).compactMap { $0["node-name"]?.stringValue }
            .filter { $0.hasPrefix(nodePrefix) && !$0.hasPrefix("\(nodePrefix)dev") }
    }

    /// Unplugs launch drives whose image is older than `olderThan`, and
    /// deletes their images. The guest copies the installer within seconds,
    /// so a drive is only needed briefly.
    static func removeStale(qmp: QMPClient, directory: URL, olderThan: Duration) async {
        let now = Date()
        for node in (try? await attachedNodes(qmp: qmp)) ?? [] {
            let short = String(node.dropFirst(nodePrefix.count))
            let image = directory.appending(path: "\(short).img")
            let modified = (try? FileManager.default.attributesOfItem(atPath: image.path(percentEncoded: false)))?[.modificationDate] as? Date
            let age = modified.map { now.timeIntervalSince($0) } ?? .infinity
            guard age >= Double(olderThan.components.seconds) else { continue }
            _ = try? await qmp.execute("device_del", arguments: ["id": .string("\(nodePrefix)dev\(short)")])
            // The block node can only go once the device is gone.
            for _ in 0..<20 {
                if (try? await qmp.execute("blockdev-del", arguments: ["node-name": .string(node)])) != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? FileManager.default.removeItem(at: image)
        }
    }
}
