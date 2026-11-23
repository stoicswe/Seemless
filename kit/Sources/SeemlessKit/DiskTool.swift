import Foundation

/// Disk images and firmware state (docs/02 storage layout and lifecycle).
///
/// Model: a sealed, read-only `base.qcow2` golden image per Windows build, and
/// a per-VM `system.qcow2` overlay backed by it. "Reset Windows" recreates the
/// overlay. Before an image exists, a VM can use a standalone disk.
public struct DiskTool: Sendable {
    public var stack: HostStack

    public init(stack: HostStack) { self.stack = stack }

    public struct ImageInfo: Sendable, Equatable {
        public var format: String
        public var virtualSize: UInt64
        public var actualSize: UInt64
        /// Absolute path of the backing file, if this is an overlay.
        public var backingFile: String?
        public var snapshots: [Snapshot]
    }

    public struct Snapshot: Sendable, Equatable {
        public var id: String
        public var name: String
        public var date: Date
        public var vmStateSize: UInt64
    }

    /// Creates a sparse qcow2 image.
    public func createDisk(at url: URL, sizeGiB: Int) async throws {
        try refuseOverwrite(url)
        try await qemuImg(["create", "-q", "-f", "qcow2", "-o", "lazy_refcounts=on",
                           path(url), "\(sizeGiB)G"])
    }

    /// Creates `overlay` backed by `base`. The base is referenced by absolute
    /// path so the overlay works from any directory.
    public func createOverlay(at overlay: URL, base: URL) async throws {
        try refuseOverwrite(overlay)
        guard FileManager.default.fileExists(atPath: path(base)) else {
            throw DiskError.missing(path(base))
        }
        try await qemuImg(["create", "-q", "-f", "qcow2", "-o", "lazy_refcounts=on",
                           "-b", path(base.standardizedFileURL), "-F", "qcow2", path(overlay)])
    }

    /// Discards everything written to an overlay since it was created.
    public func resetOverlay(_ overlay: URL) async throws {
        let info = try await info(overlay)
        guard let backing = info.backingFile else { throw DiskError.notAnOverlay(path(overlay)) }
        try FileManager.default.removeItem(at: overlay)
        try await createOverlay(at: overlay, base: URL(filePath: backing))
    }

    public func info(_ url: URL) async throws -> ImageInfo {
        let out = try await qemuImg(["info", "--output=json", "-U", path(url)])
        let json = try JSONDecoder().decode(JSONValue.self, from: out.stdout)
        let snaps = (json["snapshots"]?.arrayValue ?? []).map { s in
            Snapshot(
                id: s["id"]?.stringValue ?? "",
                name: s["name"]?.stringValue ?? "",
                date: Date(timeIntervalSince1970: s["date-sec"]?.doubleValue ?? 0),
                vmStateSize: UInt64(s["vm-state-size"]?.doubleValue ?? 0))
        }
        return ImageInfo(
            format: json["format"]?.stringValue ?? "?",
            virtualSize: UInt64(json["virtual-size"]?.doubleValue ?? 0),
            actualSize: UInt64(json["actual-size"]?.doubleValue ?? 0),
            backingFile: json["full-backing-filename"]?.stringValue ?? json["backing-filename"]?.stringValue,
            snapshots: snaps)
    }

    // MARK: Offline snapshots (VM stopped). Live snapshots depend on S6.

    public func createSnapshot(_ url: URL, name: String) async throws {
        try validateSnapshotName(name)
        try await qemuImg(["snapshot", "-c", name, path(url)])
    }

    public func applySnapshot(_ url: URL, name: String) async throws {
        try validateSnapshotName(name)
        try await qemuImg(["snapshot", "-a", name, path(url)])
    }

    public func deleteSnapshot(_ url: URL, name: String) async throws {
        try validateSnapshotName(name)
        try await qemuImg(["snapshot", "-d", name, path(url)])
    }

    /// Grows a disk. Shrinking is refused: it would cut off NTFS.
    public func resize(_ url: URL, toGiB sizeGiB: Int) async throws {
        let current = try await info(url).virtualSize
        let wanted = UInt64(sizeGiB) * 1 << 30
        guard wanted >= current else { throw DiskError.wouldShrink(current: current, requested: wanted) }
        try await qemuImg(["resize", "-q", path(url), "\(sizeGiB)G"])
    }

    // MARK: Firmware

    /// aarch64 edk2 needs a 64 MiB variable store and QEMU ships no aarch64
    /// template, so a VM starts from a zeroed file (S1 finding).
    public static let efiVarsSize: UInt64 = 64 << 20

    public static func createEFIVars(at url: URL) throws {
        try refuseOverwrite(url)
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw DiskError.cannotCreate(url.path(percentEncoded: false))
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: efiVarsSize)
    }

    // MARK: Helpers

    public enum DiskError: Error, Equatable, CustomStringConvertible {
        case exists(String), missing(String), cannotCreate(String), notAnOverlay(String)
        case invalidSnapshotName(String)
        case wouldShrink(current: UInt64, requested: UInt64)

        public var description: String {
            switch self {
            case .exists(let p): return "refusing to overwrite \(p)"
            case .missing(let p): return "not found: \(p)"
            case .cannotCreate(let p): return "cannot create \(p)"
            case .notAnOverlay(let p): return "\(p) has no backing image, so it cannot be reset"
            case .invalidSnapshotName(let n): return "invalid snapshot name '\(n)' (use letters, digits, - _ .)"
            case .wouldShrink(let c, let r): return "refusing to shrink disk from \(c >> 30) GiB to \(r >> 30) GiB"
            }
        }
    }

    private func validateSnapshotName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 64,
              name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            throw DiskError.invalidSnapshotName(name)
        }
    }

    private static func refuseOverwrite(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw DiskError.exists(url.path(percentEncoded: false))
        }
    }
    private func refuseOverwrite(_ url: URL) throws { try Self.refuseOverwrite(url) }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    @discardableResult
    private func qemuImg(_ args: [String]) async throws -> ProcessRunner.Output {
        try await ProcessRunner.run(stack.qemuImg, args)
    }
}
