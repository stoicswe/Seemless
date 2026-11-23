import Foundation

/// The repository's `image/` directory: answer-file templates, WinPE scripts
/// and recipes (docs/03).
public struct ImageAssets: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public var autounattend: URL { root.appending(path: "unattend/autounattend.xml") }
    public var unattend: URL { root.appending(path: "unattend/unattend.xml") }
    public var winpe: URL { root.appending(path: "winpe", directoryHint: .isDirectory) }
    public func recipe(_ name: String) -> URL { root.appending(path: "recipes/\(name)", directoryHint: .isDirectory) }

    /// `$SEEMLESS_IMAGE_ASSETS`, else `image/` in the repository containing
    /// the running executable or the current directory.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> ImageAssets? {
        if let explicit = environment["SEEMLESS_IMAGE_ASSETS"], !explicit.isEmpty {
            return ImageAssets(root: URL(filePath: explicit, directoryHint: .isDirectory))
        }
        let starts = [
            URL(filePath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent(),
            URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        ]
        for start in starts {
            var dir = start
            for _ in 0..<8 {
                let candidate = ImageAssets(root: dir.appending(path: "image", directoryHint: .isDirectory))
                if FileManager.default.fileExists(atPath: candidate.winpe.appending(path: "apply.cmd").path(percentEncoded: false)) {
                    return candidate
                }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }
}

/// The contents of the SEEMLESS setup disk that drives an unattended install
/// (docs/03 stage 3 "Stage payload").
///
/// Layout on the disk:
/// ```
/// autounattend.xml          found by Windows Setup in the root of removable media
/// seemless/SEEMLESS.MARK    marker the scripts search for
/// seemless/apply.cmd        WinPE installer, plus config.cmd, unattend.xml,
///                           SetupComplete.cmd, firstboot.cmd
/// seemless/recipe/...       removal recipe
/// seemless/drivers/...      optional .inf drivers to inject
/// seemless/agent/...        optional guest agent files
/// seemless/result/          written by the guest: apply.log, status.txt, inventories
/// ```
public struct SetupPayload: Sendable {
    public struct Settings: Sendable, Equatable {
        public var imageIndex: Int
        public var computerName: String
        public var username: String
        public var password: String
        /// Windows time zone ID, e.g. "W. Europe Standard Time".
        public var timeZone: String
        /// BCP-47 language of the image, e.g. "en-US".
        public var language: String
        public var inputLocale: String
        public var userLocale: String
        /// Set only when the user explicitly accepted Microsoft's licence terms
        /// on the host. Otherwise Windows shows its licence page.
        public var hideLicensePage: Bool
        public var compactOS: Bool
        public var writeInventory: Bool
        public var testSigning: Bool
        public var recipeName: String

        public init(imageIndex: Int, computerName: String = "SEEMLESS", username: String = "Seemless",
                    password: String, timeZone: String = "UTC", language: String = "en-US",
                    inputLocale: String? = nil, userLocale: String? = nil,
                    hideLicensePage: Bool = false, compactOS: Bool = true, writeInventory: Bool = true,
                    testSigning: Bool = false, recipeName: String = "seemless-default") {
            self.imageIndex = imageIndex
            self.computerName = computerName
            self.username = username
            self.password = password
            self.timeZone = timeZone
            self.language = language
            self.inputLocale = inputLocale ?? language
            self.userLocale = userLocale ?? language
            self.hideLicensePage = hideLicensePage
            self.compactOS = compactOS
            self.writeInventory = writeInventory
            self.testSigning = testSigning
            self.recipeName = recipeName
        }

        /// Values Windows would reject or that could break the generated files.
        public var validationErrors: [String] {
            var e: [String] = []
            if imageIndex < 1 { e.append("imageIndex must be >= 1") }
            // NetBIOS name: 1-15 chars, letters, digits, hyphen; not all digits.
            if computerName.wholeMatch(of: /[A-Za-z0-9-]{1,15}/) == nil || computerName.allSatisfy(\.isNumber) {
                e.append("computerName must be 1-15 letters, digits or hyphens")
            }
            if username.wholeMatch(of: /[A-Za-z0-9._-]{1,20}/) == nil || ["administrator", "guest"].contains(username.lowercased()) {
                e.append("username must be 1-20 letters, digits, . _ - and not a built-in account")
            }
            if password.count < 12 || password.contains(where: { $0.isNewline }) { e.append("password must be at least 12 characters, no newlines") }
            for (name, value) in [("language", language), ("inputLocale", inputLocale), ("userLocale", userLocale)]
                where value.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) == nil {
                e.append("\(name) must be a language tag like en-US")
            }
            if timeZone.isEmpty || timeZone.contains(where: { "<>&\"".contains($0) }) { e.append("timeZone is invalid") }
            if recipeName.wholeMatch(of: /[A-Za-z0-9._-]+/) == nil { e.append("recipeName is invalid") }
            return e
        }
    }

    public var assets: ImageAssets
    public var settings: Settings

    public init(assets: ImageAssets, settings: Settings) {
        self.assets = assets
        self.settings = settings
    }

    public enum PayloadError: Error, CustomStringConvertible {
        case invalid([String]), missingAsset(String), unfilledPlaceholder(String, String)
        public var description: String {
            switch self {
            case .invalid(let e): return "invalid setup settings: " + e.joined(separator: "; ")
            case .missingAsset(let p): return "image asset missing: \(p)"
            case .unfilledPlaceholder(let file, let key): return "\(file) still contains {{\(key)}}"
            }
        }
    }

    /// Windows' unattend password encoding: base64(UTF-16LE(password + "Password")).
    /// Obfuscation only (docs/03); the file is deleted after first boot.
    public static func encodeUnattendPassword(_ password: String) -> String {
        var data = Data()
        for unit in (password + "Password").utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        return data.base64EncodedString()
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Every file of the payload, by path relative to the disk root.
    public func render() throws -> [String: Data] {
        let errors = settings.validationErrors
        guard errors.isEmpty else { throw PayloadError.invalid(errors) }
        let s = settings
        let values: [String: String] = [
            "UI_LANGUAGE": s.language,
            "INPUT_LOCALE": s.inputLocale,
            "USER_LOCALE": s.userLocale,
            "COMPUTER_NAME": s.computerName,
            "TIME_ZONE": s.timeZone,
            "USERNAME": s.username,
            "PASSWORD_ENCODED": Self.encodeUnattendPassword(s.password),
            "HIDE_EULA_PAGE": s.hideLicensePage ? "true" : "false",
        ]
        var files: [String: Data] = [:]
        files["autounattend.xml"] = try fill(assets.autounattend, values)
        files["seemless/unattend.xml"] = try fill(assets.unattend, values)
        files["seemless/SEEMLESS.MARK"] = Data("Seemless setup payload\r\n".utf8)
        for script in ["apply.cmd", "SetupComplete.cmd", "firstboot.cmd"] {
            files["seemless/\(script)"] = crlf(try read(assets.winpe.appending(path: script)))
        }
        files["seemless/config.cmd"] = crlf(Data("""
            @echo off
            rem Generated by SeemlessKit. Read by apply.cmd.
            set SL_INDEX=\(s.imageIndex)
            set SL_COMPACT=\(s.compactOS ? 1 : 0)
            set SL_INVENTORY=\(s.writeInventory ? 1 : 0)
            set SL_TESTSIGNING=\(s.testSigning ? 1 : 0)
            set SL_RECIPE=\(s.recipeName)

            """.utf8))
        let recipe = assets.recipe(s.recipeName)
        guard FileManager.default.fileExists(atPath: recipe.path(percentEncoded: false)) else {
            throw PayloadError.missingAsset(recipe.path(percentEncoded: false))
        }
        for (rel, data) in try collect(recipe) where !rel.hasSuffix("README.md") && !rel.hasSuffix(".gitkeep") {
            files["seemless/recipe/\(rel)"] = rel.hasSuffix(".txt") || rel.hasSuffix(".reg") ? crlf(data) : data
        }
        return files
    }

    private func fill(_ template: URL, _ values: [String: String]) throws -> Data {
        var text = String(decoding: try read(template), as: UTF8.self)
        for (key, value) in values { text = text.replacingOccurrences(of: "{{\(key)}}", with: Self.xmlEscape(value)) }
        if let m = text.firstMatch(of: /\{\{([A-Z_]+)\}\}/) {
            throw PayloadError.unfilledPlaceholder(template.lastPathComponent, String(m.1))
        }
        return Data(text.utf8)
    }

    private func read(_ url: URL) throws -> Data {
        guard let d = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
            throw PayloadError.missingAsset(url.path(percentEncoded: false))
        }
        return d
    }

    /// cmd.exe mis-parses labels and `goto` in LF-only batch files.
    func crlf(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    private func collect(_ dir: URL) throws -> [(String, Data)] {
        let base = dir.standardizedFileURL.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(String, Data)] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            var rel = url.standardizedFileURL.path(percentEncoded: false)
            if rel.hasPrefix(base) { rel.removeFirst(base.count) }
            out.append((rel.trimmingCharacters(in: CharacterSet(charactersIn: "/")), try read(url)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - FAT disk image

    /// Writes the payload to an MBR-partitioned FAT32 raw image, the format
    /// Windows reads from a USB disk. No root needed (hdiutil/diskutil).
    /// `extraDirectories` maps disk paths (e.g. "seemless/drivers") to host
    /// directories copied in as-is.
    public func writeDiskImage(to image: URL, sizeMiB: Int = 512,
                               extraDirectories: [String: URL] = [:]) async throws {
        let files = try render()
        try? FileManager.default.removeItem(at: image)
        try await FATImage.create(at: image, sizeMiB: sizeMiB, label: "SEEMLESS")
        try await FATImage.withMounted(image, readOnly: false) { root in
            for (rel, data) in files {
                let url = root.appending(path: rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try FileManager.default.createDirectory(at: root.appending(path: "seemless/result"), withIntermediateDirectories: true)
            for (rel, source) in extraDirectories {
                let dest = root.appending(path: rel, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: dest)
            }
        }
    }

    /// What the guest left in `seemless/result` (after the VM has stopped).
    public struct Result: Sendable, Equatable {
        /// "APPLIED", "FIRSTBOOT_OK", "ERROR <stage> <detail>", "RUNNING" (died
        /// mid-way), or nil if WinPE never ran apply.cmd.
        public var status: String?
        public var files: [String]

        public var succeeded: Bool { status == "FIRSTBOOT_OK" }
    }

    /// Copies `seemless/result` out of a payload image into `destination`.
    public static func collectResult(from image: URL, into destination: URL) async throws -> Result {
        try await FATImage.withMounted(image, readOnly: true) { root in
            let results = root.appending(path: "seemless/result", directoryHint: .isDirectory)
            let fm = FileManager.default
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let names = (try? fm.contentsOfDirectory(atPath: results.path(percentEncoded: false)))?
                .filter { !$0.hasPrefix("._") }.sorted() ?? []
            for name in names {
                let dest = destination.appending(path: name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: results.appending(path: name), to: dest)
            }
            let status = (try? String(contentsOf: results.appending(path: "status.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(status: status?.isEmpty == true ? nil : status, files: names)
        }
    }
}

/// Raw FAT32 disk images via hdiutil/diskutil.
enum FATImage {
    static let hdiutil = URL(filePath: "/usr/bin/hdiutil")
    static let diskutil = URL(filePath: "/usr/sbin/diskutil")

    static func create(at image: URL, sizeMiB: Int, label: String) async throws {
        guard FileManager.default.createFile(atPath: image.path(percentEncoded: false), contents: nil) else {
            throw DiskTool.DiskError.cannotCreate(image.path(percentEncoded: false))
        }
        let h = try FileHandle(forWritingTo: image)
        try h.truncate(atOffset: UInt64(sizeMiB) << 20)
        try h.close()
        let device = try await attach(image, mount: false)
        do {
            try await ProcessRunner.run(diskutil, ["partitionDisk", device, "1", "MBR", "MS-DOS FAT32", label, "100%"])
            try await ProcessRunner.run(hdiutil, ["detach", "-quiet", device])
        } catch {
            _ = try? await ProcessRunner.run(hdiutil, ["detach", "-force", "-quiet", device], check: false)
            throw error
        }
    }

    /// Mounts the image's first partition at a private mount point.
    static func withMounted<T: Sendable>(_ image: URL, readOnly: Bool, _ body: (URL) async throws -> T) async throws -> T {
        let device = try await attach(image, mount: false, readOnly: readOnly)
        let mount = URL(filePath: "/tmp/sl-fat-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            var args = ["mount"]
            if readOnly { args.append("readOnly") }
            args += ["-mountPoint", mount.path(percentEncoded: false), "\(device)s1"]
            try await ProcessRunner.run(diskutil, args)
            let result = try await body(mount)
            if !readOnly {
                // Drop the ._ AppleDouble files macOS writes on FAT.
                _ = try? await ProcessRunner.run(URL(filePath: "/usr/sbin/dot_clean"), ["-m", mount.path(percentEncoded: false)], check: false)
            }
            try await ProcessRunner.run(hdiutil, ["detach", "-quiet", device])
            try? FileManager.default.removeItem(at: mount)
            return result
        } catch {
            _ = try? await ProcessRunner.run(hdiutil, ["detach", "-force", "-quiet", device], check: false)
            try? FileManager.default.removeItem(at: mount)
            throw error
        }
    }

    /// Attaches without mounting and returns the whole-disk device (/dev/diskN).
    static func attach(_ image: URL, mount: Bool, readOnly: Bool = false) async throws -> String {
        var args = ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", "-plist"]
        if readOnly { args.append("-readonly") }
        args.append(image.path(percentEncoded: false))
        let out = try await ProcessRunner.run(hdiutil, args)
        guard let plist = try PropertyListSerialization.propertyList(from: out.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let dev = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else {
            throw DiskTool.DiskError.cannotCreate("could not attach \(image.lastPathComponent)")
        }
        return dev
    }
}
