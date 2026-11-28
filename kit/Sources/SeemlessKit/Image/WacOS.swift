import Foundation

/// WacOS (https://github.com/renzyxx/WacOS): a macOS-style shell for
/// Windows 11 (menu bar, Dock, Finder...) that replaces the taskbar and
/// Start menu. An EXPERIMENTAL option of VM setup (owner, 2026-11-24;
/// docs/03 "Optional: WacOS").
///
/// Licence: WacOS is source-available, NOT open source. Its licence allows
/// personal use of the official release and forbids redistributing it or
/// bundling it with other software. So Seemless ships none of it: the VM
/// itself downloads the pinned official release from GitHub after first
/// setup (when its network is on), checks the SHA-256 below and runs
/// WacOS's own silent installer. The person creating the VM accepts the
/// WacOS licence; Seemless never accepts it for them.
public struct WacOSRelease: Codable, Sendable, Equatable {
    /// Release tag, e.g. "build-46".
    public var tag: String
    /// Commit the tag points at (also in scripts/versions.lock).
    public var commit: String
    /// The release asset, only ever from github.com/renzyxx/WacOS/releases.
    public var url: String
    /// SHA-256 of the asset, lowercase hex (GitHub's published digest).
    public var sha256: String
    public var size: Int

    public init(tag: String, commit: String, url: String, sha256: String, size: Int) {
        self.tag = tag
        self.commit = commit
        self.url = url
        self.sha256 = sha256
        self.size = size
    }

    /// Pinned release. Bump deliberately, with scripts/versions.lock.
    public static let pinned = WacOSRelease(
        tag: "build-46",
        commit: "629c7985b319435d5140deb6d16f3989ba3e398b",
        url: "https://github.com/renzyxx/WacOS/releases/download/build-46/WacOS-2026-11-24.zip",
        sha256: "70bdbb9778e80e81189e797e4b25180c6d186bc6f12b4cf35df26ed3cc89dbcf",
        size: 187_238_602)

    public static let licenseURL = URL(string: "https://github.com/renzyxx/WacOS/blob/main/LICENSE")!
    public static let projectURL = URL(string: "https://github.com/renzyxx/WacOS")!
    static let releasePrefix = "https://github.com/renzyxx/WacOS/releases/download/"

    /// Checks the fields before they go into a guest script.
    public var validationErrors: [String] {
        var e: [String] = []
        if tag.wholeMatch(of: /[A-Za-z0-9._-]{1,40}/) == nil { e.append("WacOS tag '\(tag)' is not a plain tag name") }
        if commit.wholeMatch(of: /[0-9a-f]{40}/) == nil { e.append("WacOS commit must be 40 hex characters") }
        if sha256.wholeMatch(of: /[0-9a-f]{64}/) == nil { e.append("WacOS sha256 must be 64 lowercase hex characters") }
        if !url.hasPrefix(Self.releasePrefix + tag + "/")
            || url.wholeMatch(of: /[A-Za-z0-9:\/._-]+\.zip/) == nil {
            e.append("WacOS url must be a .zip of release \(tag) on github.com/renzyxx/WacOS")
        }
        if size <= 0 { e.append("WacOS size must be positive") }
        return e
    }
}

extension VMConfig {
    /// True when the VM was set up with the experimental WacOS shell.
    public var hasWacOS: Bool { wacos != nil }
}
