import Foundation

/// What a new user's Mac needs before the first install (WP3.4, docs/07
/// "First run"). Pure: the facts are gathered by `HostFacts.current()` and
/// can be faked in tests.
public enum FirstRun {
    /// Free space asked for before an install: Windows plus the setup files
    /// take ~15–20 GB of the sparse 64 GB disk (docs/07: ~25 GB).
    public static let requiredFreeBytes: Int64 = 25 * 1_000_000_000

    /// Microsoft's Windows 11 on Arm download page. Seemless never ships
    /// or downloads Windows itself.
    public static let windowsDownloadPage = URL(string: "https://www.microsoft.com/software-download/windows11arm64")!

    public struct HostFacts: Sendable, Equatable {
        public var isAppleSilicon: Bool
        public var isTranslated: Bool
        public var macOSMajor: Int
        public var macOSVersion: String
        /// Free bytes on the volume of the storage root (nil: unknown).
        public var freeBytes: Int64?
        public var missingStackFiles: [String]
        public var hasImageAssets: Bool
        public var drivers: GuestDrivers?

        public init(isAppleSilicon: Bool, isTranslated: Bool = false, macOSMajor: Int, macOSVersion: String = "",
                    freeBytes: Int64?, missingStackFiles: [String] = [], hasImageAssets: Bool = true,
                    drivers: GuestDrivers?) {
            self.isAppleSilicon = isAppleSilicon
            self.isTranslated = isTranslated
            self.macOSMajor = macOSMajor
            self.macOSVersion = macOSVersion
            self.freeBytes = freeBytes
            self.missingStackFiles = missingStackFiles
            self.hasImageAssets = hasImageAssets
            self.drivers = drivers
        }

        /// This Mac. `storageRoot` is where VMs will live (its volume's free
        /// space is checked; the folder need not exist yet).
        public static func current(storageRoot: URL, stack: HostStack?, assets: ImageAssets?,
                                   drivers: GuestDrivers?) -> HostFacts {
            func sysctl(_ name: String) -> Int {
                var v: Int32 = 0
                var size = MemoryLayout<Int32>.size
                return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
            }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            var dir = storageRoot
            while !FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)), dir.pathComponents.count > 1 {
                dir.deleteLastPathComponent()
            }
            let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            return HostFacts(
                isAppleSilicon: sysctl("hw.optional.arm64") == 1,
                isTranslated: sysctl("sysctl.proc_translated") == 1,
                macOSMajor: os.majorVersion,
                macOSVersion: "\(os.majorVersion).\(os.minorVersion)",
                freeBytes: free,
                missingStackFiles: stack?.missingFiles() ?? ["qemu-system-aarch64"],
                hasImageAssets: assets != nil,
                drivers: drivers)
        }
    }

    public struct Requirement: Sendable, Equatable, Identifiable {
        public enum ID: String, Sendable { case appleSilicon, macOS, diskSpace, components, graphicsDriver, windowsISO }
        public var id: ID
        public var title: String
        public var detail: String
        public var met: Bool
        /// Unmet blocking requirements stop the install; others only warn.
        public var blocking: Bool
    }

    /// The checklist shown on the welcome screen. The ISO line is never met
    /// here: the user picks it next.
    public static func requirements(_ f: HostFacts) -> [Requirement] {
        var r: [Requirement] = []
        r.append(Requirement(
            id: .appleSilicon, title: "A Mac with Apple silicon",
            detail: f.isAppleSilicon && !f.isTranslated ? "This Mac has Apple silicon."
                : f.isTranslated ? "Seemless is running under Rosetta. Open it as a native Apple silicon app."
                : "Seemless needs an M-series Mac: Windows for Arm runs on Apple's virtualisation.",
            met: f.isAppleSilicon && !f.isTranslated, blocking: true))
        r.append(Requirement(
            id: .macOS, title: "macOS 26 or later",
            detail: f.macOSMajor >= 26 ? "macOS \(f.macOSVersion.isEmpty ? String(f.macOSMajor) : f.macOSVersion)."
                : "Update macOS to version 26 or later.",
            met: f.macOSMajor >= 26, blocking: true))
        let enough = f.freeBytes.map { $0 >= requiredFreeBytes } ?? true
        r.append(Requirement(
            id: .diskSpace, title: "About 25 GB of free space",
            detail: f.freeBytes.map { "\(formatBytes($0)) free." + (enough ? "" : " Free up space before installing.") }
                ?? "Free space could not be read.",
            met: enough, blocking: true))
        r.append(Requirement(
            id: .components, title: "Seemless components",
            detail: f.missingStackFiles.isEmpty && f.hasImageAssets ? "Virtual machine and install files are present."
                : "Missing: " + (f.missingStackFiles + (f.hasImageAssets ? [] : ["install scripts (image/)"])).joined(separator: ", ")
                  + ". Reinstall Seemless.",
            met: f.missingStackFiles.isEmpty && f.hasImageAssets, blocking: true))
        r.append(Requirement(
            id: .graphicsDriver, title: "3D graphics driver for Windows",
            detail: f.drivers.map { "Installed into Windows during setup (\($0.driverNames.joined(separator: ", ")))." }
                ?? "Not found. Windows will install with basic graphics only (no 3D, fixed resolution).",
            met: f.drivers != nil, blocking: false))
        r.append(Requirement(
            id: .windowsISO, title: "Your own Windows 11 ARM64 ISO",
            detail: "Download it from Microsoft, then choose it on the next step. Windows needs your own licence.",
            met: false, blocking: false))
        return r
    }

    /// True when nothing blocking is unmet.
    public static func canInstall(_ f: HostFacts) -> Bool {
        requirements(f).allSatisfy { $0.met || !$0.blocking }
    }

    static func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
