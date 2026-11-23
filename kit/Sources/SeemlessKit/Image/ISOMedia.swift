import Foundation

/// Read-only access to a Windows installation ISO (docs/03 stage 2).
public enum ISOMedia {
    public struct Inspection: Sendable, Equatable {
        public var iso: URL
        /// `sources/install.wim` or `sources/install.esd` relative to the ISO root.
        public var installImagePath: String
        public var wim: WIMInfo
    }

    public enum MediaError: Error, CustomStringConvertible {
        case notFound(String), noInstallImage, attachFailed(String)
        public var description: String {
            switch self {
            case .notFound(let p): return "not found: \(p)"
            case .noInstallImage: return "no sources/install.wim or sources/install.esd: not Windows installation media"
            case .attachFailed(let why): return "could not open the ISO: \(why)"
            }
        }
    }

    /// Mounts the ISO read-only and invisibly, runs `body` with the mount
    /// point, and always detaches.
    public static func withMounted<T: Sendable>(_ iso: URL, _ body: (URL) async throws -> T) async throws -> T {
        guard FileManager.default.fileExists(atPath: iso.path(percentEncoded: false)) else {
            throw MediaError.notFound(iso.path(percentEncoded: false))
        }
        let mount = URL(filePath: "/tmp/sl-iso-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            try await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"),
                                        ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen",
                                         "-mountpoint", mount.path(percentEncoded: false), iso.path(percentEncoded: false)])
        } catch let f as ProcessRunner.Failure {
            try? FileManager.default.removeItem(at: mount)
            throw MediaError.attachFailed(f.output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            let result = try await body(mount)
            await detach(mount)
            return result
        } catch {
            await detach(mount)
            throw error
        }
    }

    static func detach(_ mount: URL) async {
        _ = try? await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", "-quiet", mount.path(percentEncoded: false)], check: false)
        try? FileManager.default.removeItem(at: mount)
    }

    /// Reads the edition catalogue of the ISO's install image.
    public static func inspect(_ iso: URL) async throws -> Inspection {
        try await withMounted(iso) { root in
            for rel in ["sources/install.wim", "sources/install.esd"] {
                let url = root.appending(path: rel)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    return Inspection(iso: iso, installImagePath: rel, wim: try WIMInfo.read(url))
                }
            }
            throw MediaError.noInstallImage
        }
    }
}
