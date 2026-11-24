import Foundation

/// The Windows ARM64 guest drivers injected while installing (docs/03 step
/// 5): the `viogpu3d` 3D display driver (Neptune/Triton UMD), and, when
/// present, `netkvm` (network) and `vioserial` (agent channel). One
/// subfolder per driver holding its `.inf`.
///
/// Nothing here downloads drivers or decides where a release gets them
/// (owner question Q13); this only finds a folder that is already there.
public struct GuestDrivers: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// The 3D driver's INF; without it Windows only has Basic Display.
    public static let graphicsINF = "viogpu3d.inf"

    /// `.inf` file names (lowercased) anywhere under `root`, sorted.
    public var infFiles: [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var names: [String] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "inf" {
            names.append(url.lastPathComponent.lowercased())
        }
        return names.sorted()
    }

    public var hasGraphicsDriver: Bool { infFiles.contains(Self.graphicsINF) }

    /// Driver names for display ("viogpu3d", "netkvm", …).
    public var driverNames: [String] { infFiles.map { String($0.dropLast(4)) } }

    /// `$SEEMLESS_GUEST_DRIVERS`, else `Contents/Resources/guest-drivers` of
    /// the app bundle running this code, else `build/guest-drivers` in the
    /// repository containing the executable or the current directory. Only
    /// folders holding the 3D driver count.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: URL = URL(filePath: CommandLine.arguments.first ?? ""),
                              currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath,
                                                          directoryHint: .isDirectory)) -> GuestDrivers? {
        if let explicit = environment["SEEMLESS_GUEST_DRIVERS"], !explicit.isEmpty {
            let d = GuestDrivers(root: URL(filePath: explicit, directoryHint: .isDirectory))
            return d.hasGraphicsDriver ? d : nil
        }
        let exeDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = exeDir.deletingLastPathComponent()
        if contents.lastPathComponent == "Contents" {
            let bundled = GuestDrivers(root: contents.appending(path: "Resources/guest-drivers", directoryHint: .isDirectory))
            if bundled.hasGraphicsDriver { return bundled }
        }
        for start in [exeDir, currentDirectory] {
            var dir = start
            for _ in 0..<8 {
                let candidate = GuestDrivers(root: dir.appending(path: "build/guest-drivers", directoryHint: .isDirectory))
                if candidate.hasGraphicsDriver { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }
}
