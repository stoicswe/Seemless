import Foundation

/// Runs the unattended Windows install end to end (docs/03 stages 1-6):
/// inspect the ISO, create the VM, write the payload disk, boot WinPE with
/// both attached, wait for the guest to power off, collect results.
///
/// Sealing a reusable golden image (stage 7) comes later; for now the VM's
/// own system disk holds the installed Windows.
public struct ImageBuilder: Sendable {
    public struct Request: Sendable {
        public var iso: URL
        public var vm: VMConfig
        /// WIM image index; nil picks Pro, else the first supported edition.
        public var imageIndex: Int?
        public var username: String = "Seemless"
        public var recipe: String = "seemless-default"
        /// Only true when the person explicitly accepted Microsoft's licence
        /// terms. Otherwise Windows shows its licence page during setup.
        public var acceptWindowsLicense: Bool = false
        public var display: LaunchOptions.Display = .cocoaWindow
        public var timeout: Duration = .seconds(120 * 60)
        public var drivers: URL?
        /// Agent folder copied into Windows and installed at first boot.
        /// nil: the guest tools' agent (`GuestTools.locate()`), so every VM
        /// the pipeline builds gets the agent (WP4.3); see `installAgent`.
        public var agent: URL?
        /// false: no agent at all, even if `GuestTools.locate()` finds one.
        public var installAgent: Bool = true
        public var testSigning: Bool = false

        public init(iso: URL, vm: VMConfig) {
            self.iso = iso
            self.vm = vm
        }
    }

    public struct Report: Sendable {
        public var image: WIMInfo.Image
        public var result: SetupPayload.Result
        public var resultDirectory: URL
        public var vmFiles: VMFiles
        public var elapsed: Duration
        public var timedOut: Bool
    }

    public enum BuildError: Error, CustomStringConvertible {
        case vmExists(String), noSupportedImage([String]), noSuchIndex(Int), unsupported(Int, [String])
        public var description: String {
            switch self {
            case .vmExists(let n): return "VM '\(n)' already exists; delete it or choose another --name"
            case .noSupportedImage(let why): return "no supported edition on this ISO: " + why.joined(separator: "; ")
            case .noSuchIndex(let i): return "the ISO has no image with index \(i)"
            case .unsupported(let i, let why): return "image \(i) is not supported: " + why.joined(separator: "; ")
            }
        }
    }

    /// Coarse stages for progress UIs (the log lines carry the detail).
    public enum Phase: String, Sendable, CaseIterable {
        /// Reading the ISO and choosing the edition.
        case checkingMedia
        /// Creating the VM, the Windows account and the setup disk.
        case preparing
        /// The VM is running Windows Setup and its first boot (5–15 minutes).
        case installing
        /// The VM powered off; reading the result.
        case finishing
    }

    public var layout: StorageLayout
    public var stack: HostStack
    public var assets: ImageAssets

    public init(layout: StorageLayout, stack: HostStack, assets: ImageAssets) {
        self.layout = layout
        self.stack = stack
        self.assets = assets
    }

    public func build(_ request: Request, phase: @Sendable (Phase) -> Void = { _ in },
                      log: @Sendable (String) -> Void) async throws -> Report {
        let start = ContinuousClock.now
        phase(.checkingMedia)

        log("inspecting \(request.iso.lastPathComponent)")
        let inspection = try await ISOMedia.inspect(request.iso)
        let image = try choose(from: inspection.wim, index: request.imageIndex)
        log("edition: \(image.name) (index \(image.index), build \(image.build).\(image.spBuild), \(image.architecture), \(image.defaultLanguage ?? image.languages.first ?? "?"))")

        phase(.preparing)
        let store = VMStore(layout: layout, stack: stack)
        guard !store.exists(request.vm.name) else { throw BuildError.vmExists(request.vm.name) }
        // The first real start (licence page, first sign-in) runs offline
        // too; the cable is plugged in once Windows reaches the desktop
        // (owner, 2026-11-24; VMConfig.offlineUntilSetupDone).
        var savedConfig = request.vm
        savedConfig.offlineUntilSetupDone = true
        let files = try await store.create(savedConfig)
        log("created VM '\(request.vm.name)' with a blank \(request.vm.diskSizeGiB) GiB disk")

        // One Windows account per VM; the Keychain entry is keyed by VM name
        // and removed with the VM (VMStore.delete).
        let password = WindowsCredentials.generatePassword()
        try WindowsCredentials.store(password, account: request.vm.name, username: request.username)
        log("Windows account '\(request.username)': password stored in the Keychain (service \(WindowsCredentials.service), account \(request.vm.name))")

        let language = image.defaultLanguage ?? image.languages.first ?? "en-US"
        let settings = SetupPayload.Settings(
            imageIndex: image.index, username: request.username, password: password,
            timeZone: WindowsTimeZone.current, language: language,
            hideLicensePage: request.acceptWindowsLicense, testSigning: request.testSigning,
            recipeName: request.recipe)
        let payloadImage = files.directory.appending(path: "setup-payload.img")
        var extra: [String: URL] = [:]
        if let d = request.drivers { extra["seemless/drivers"] = d }
        if request.installAgent, let a = request.agent ?? GuestTools.locate()?.agentDirectory {
            extra["seemless/agent"] = a
            let version = GuestTools(root: a.deletingLastPathComponent()).version
            log("guest agent: \(a.path(percentEncoded: false))\(version.map { " (\($0))" } ?? "")")
        } else {
            log(request.installAgent ? "no guest agent found (build it with guest/tools/build.sh); Windows gets none"
                                     : "guest agent left out (--no-agent)")
        }
        try await SetupPayload(assets: assets, settings: settings).writeDiskImage(to: payloadImage, extraDirectories: extra)
        log("payload disk written: \(payloadImage.path(percentEncoded: false))")
        if !request.acceptWindowsLicense {
            log("Windows will show Microsoft's licence page on the VM's first start (after this build); accept it there")
        }

        // Network off while installing (docs/03): no updates pulled, no
        // Microsoft-account prompts. The saved config keeps its own setting.
        var buildConfig = request.vm
        buildConfig.network = .none
        let options = LaunchOptions(
            display: request.display,
            removableDrives: [RemovableDrive(id: "win", file: request.iso, isCDROM: true),
                              RemovableDrive(id: "payload", file: payloadImage, isCDROM: false)],
            startPaused: true,
            bootKeys: .cdPrompt)
        let run = layout.runDirectory(pid: getpid())
        let vm = VMProcess(config: buildConfig, stack: stack, files: files, options: options, runDirectory: run)
        // The system disk is empty on this boot, so pressing Space at the
        // CD prompt (BootKeys.cdPrompt) cannot pick the wrong device.
        try await vm.start()
        phase(.installing)
        log("VM started (QEMU pid \(await vm.qemuPID ?? 0)); booting Windows Setup")

        let finished = await vm.waitForExit(timeout: request.timeout)
        if !finished {
            log("timed out after \(request.timeout); forcing the VM off")
            await vm.stop(graceful: .zero)
        }
        let state = await vm.state
        log("VM stopped: \(state)")
        phase(.finishing)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let resultDir = files.logs.appending(path: "image-build-\(stamp)", directoryHint: .isDirectory)
        let result = try await SetupPayload.collectResult(from: payloadImage, into: resultDir)
        try writeManifest(files: files, inspection: inspection, image: image, request: request, result: result)
        return Report(image: image, result: result, resultDirectory: resultDir, vmFiles: files,
                      elapsed: ContinuousClock.now - start, timedOut: !finished)
    }

    func choose(from wim: WIMInfo, index: Int?) throws -> WIMInfo.Image {
        if let index {
            guard let image = wim.images.first(where: { $0.index == index }) else { throw BuildError.noSuchIndex(index) }
            guard image.isSupported else { throw BuildError.unsupported(index, image.unsupportedReasons) }
            return image
        }
        guard let image = wim.preferredImage else {
            throw BuildError.noSupportedImage(Array(Set(wim.images.flatMap(\.unsupportedReasons))).sorted())
        }
        return image
    }

    private func writeManifest(files: VMFiles, inspection: ISOMedia.Inspection, image: WIMInfo.Image,
                               request: Request, result: SetupPayload.Result) throws {
        let manifest: JSONValue = [
            "iso": .string(request.iso.lastPathComponent),
            "installImage": .string(inspection.installImagePath),
            "edition": .string(image.name),
            "editionID": .string(image.editionID ?? ""),
            "imageIndex": .number(Double(image.index)),
            "build": .string("\(image.major).\(image.minor).\(image.build).\(image.spBuild)"),
            "language": .string(image.defaultLanguage ?? ""),
            "recipe": .string(request.recipe),
            "licenseAcceptedOnHost": .bool(request.acceptWindowsLicense),
            "status": result.status.map(JSONValue.string) ?? .null,
            "builtAt": .string(ISO8601DateFormatter().string(from: Date())),
            "seemlessVersion": .string(Seemless.version),
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: files.directory.appending(path: "image-build.json"), options: .atomic)
    }
}
