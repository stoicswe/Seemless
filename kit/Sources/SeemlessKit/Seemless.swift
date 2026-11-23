import Foundation

/// Build-wide constants.
public enum Seemless {
    /// Version of SeemlessKit and seemlessctl. Bumped by release engineering (M8).
    public static let version = "0.0.1"
}

/// Host storage layout from docs/02 "Storage layout on the host".
///
/// Pure path arithmetic: nothing here touches the file system, so it is safe
/// to call from tests and can be pointed at a temporary root.
public struct StorageLayout: Sendable, Equatable {
    /// `~/Library/Application Support/Seemless` in normal use.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The default location for the current user.
    public static var `default`: StorageLayout {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StorageLayout(root: support.appending(path: "Seemless", directoryHint: .isDirectory))
    }

    public var images: URL { root.appending(path: "images", directoryHint: .isDirectory) }
    public var vms: URL { root.appending(path: "vms", directoryHint: .isDirectory) }
    public var cache: URL { root.appending(path: "cache", directoryHint: .isDirectory) }
    public var run: URL { root.appending(path: "run", directoryHint: .isDirectory) }

    /// Directory for one VM. v1 uses only `"default"`.
    public func vm(named name: String = "default") -> URL {
        vms.appending(path: name, directoryHint: .isDirectory)
    }

    /// Socket directory for one running QEMU process.
    public func runDirectory(pid: Int32) -> URL {
        run.appending(path: String(pid), directoryHint: .isDirectory)
    }

    /// Unix socket paths are limited to 104 bytes on macOS (`sun_path`),
    /// including the terminating NUL. docs/02 calls this out for `run/<pid>/`.
    public static let maxSocketPathBytes = 103

    /// Returns `true` if `path` fits in `sockaddr_un.sun_path`.
    public static func isValidSocketPath(_ path: URL) -> Bool {
        path.path(percentEncoded: false).utf8.count <= maxSocketPathBytes
    }
}
