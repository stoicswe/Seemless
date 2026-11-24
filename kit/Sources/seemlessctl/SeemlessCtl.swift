import ArgumentParser
import Foundation
import SeemlessKit

@main
struct SeemlessCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seemlessctl",
        abstract: "Headless control of the Seemless Windows runtime.",
        version: Seemless.version,
        subcommands: [VMCommand.self, ImageCommand.self, DiskCommand.self, StackCommand.self, AgentCommand.self,
                      MockAgentCommand.self, ScreenshotCommand.self, DisplayCommand.self, Paths.self]
    )
}

/// Options shared by commands that act on one VM.
struct VMSelection: ParsableArguments {
    @Option(name: .long, help: "VM name.")
    var name = "default"

    @Option(name: .long, help: ArgumentHelp("Storage root (default: ~/Library/Application Support/Seemless).", valueName: "dir"))
    var root: String?

    var layout: StorageLayout {
        root.map { StorageLayout(root: URL(filePath: $0, directoryHint: .isDirectory)) } ?? .default
    }

    func stack() throws -> HostStack {
        guard let stack = HostStack.locate() else {
            throw ValidationError("host stack not found: set SEEMLESS_PREFIX or run scripts/build-deps.sh all")
        }
        let missing = stack.missingFiles()
        guard missing.isEmpty else { throw ValidationError("host stack incomplete, missing: \(missing.joined(separator: ", "))") }
        return stack
    }

    func store() throws -> VMStore { VMStore(layout: layout, stack: try stack()) }
    var files: VMFiles { VMFiles(directory: layout.vm(named: name)) }

    func remote() throws -> VMRemote {
        guard let remote = VMRemote.attach(files) else { throw ValidationError("VM '\(name)' is not running") }
        return remote
    }

    func requireStopped() throws {
        if VMRemote.attach(files) != nil { throw ValidationError("VM '\(name)' is running; stop it first") }
    }
}

// MARK: - agent

/// Where to reach an agent: a socket path, or a running VM's agent chardev.
struct AgentTarget: ParsableArguments {
    @Option(help: ArgumentHelp("Agent socket (e.g. one served by `seemlessctl mock-agent`). Default: the VM's.", valueName: "path"))
    var socket: String?

    @OptionGroup var vm: VMSelection

    @Option(help: "Seconds to wait for the agent's Hello.")
    var timeout: Double = 10

    func connect() async throws -> AgentClient {
        let url: URL
        if let socket {
            url = URL(filePath: socket)
        } else {
            guard let remote = VMRemote.attach(vm.files) else { throw ValidationError("VM '\(vm.name)' is not running") }
            url = remote.record.run.agentSocket
        }
        var options = AgentClient.Options(capabilities: [AgentHandshake.Capability.core, AgentHandshake.Capability.system,
                                                         AgentHandshake.Capability.windows, AgentHandshake.Capability.apps,
                                                         AgentHandshake.Capability.clipboard])
        options.helloTimeout = .milliseconds(Int(timeout * 1000))
        return try await AgentClient.connect(socket: url, options: options, connectTimeout: .seconds(2))
    }
}

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Talk to the guest agent (docs/06).",
        subcommands: [Hello.self, Info.self])

    struct Hello: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Exchange Hello and print what was negotiated.")
        @OptionGroup var target: AgentTarget
        func run() async throws {
            let client = try await target.connect()
            defer { Task { await client.close() } }
            guard let n = await client.negotiated else { return }
            print("agent:        \(n.peerBuild)")
            print("protocol:     \(n.peerMajor).\(n.peerMinor) (host \(AgentHandshake.protocolMajor).\(AgentHandshake.protocolMinor))")
            print("capabilities: \(n.capabilities.joined(separator: ", "))")
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print GuestInfo (Windows build, drivers, agent version, GPU).")
        @OptionGroup var target: AgentTarget
        func run() async throws {
            let client = try await target.connect()
            defer { Task { await client.close() } }
            let info = try await client.guestInfo()
            print("windows:  \(info.osBuild)")
            print("agent:    \(info.agentVersion)")
            print("gpu:      \(info.gpuAdapter)")
            for d in info.driverVersions { print("driver:   \(d.name) \(d.version)") }
        }
    }
}

struct MockAgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mock-agent",
        abstract: "Serve a fake guest agent on a unix socket, so the host side can be tested with no VM (docs/06).",
        discussion: "The script format is documented on MockAgentScript (kit/Sources/SeemlessKit/Agent/MockAgent.swift); examples in proto/mock/.")

    @Option(help: ArgumentHelp("Socket to listen on.", valueName: "path"))
    var socket: String

    @Option(help: ArgumentHelp("JSON script.", valueName: "file"))
    var script: String?

    @Flag(help: "Exit after the first host disconnects (default: keep serving).")
    var once = false

    func run() async throws {
        let s = try script.map { try MockAgentScript.load(URL(filePath: $0)) } ?? MockAgentScript()
        let agent = MockAgent(script: s) { line in print(line) }
        setvbuf(stdout, nil, _IOLBF, 0)
        try await agent.serve(socket: URL(filePath: socket), connections: once ? 1 : nil)
    }
}

// MARK: - vm

struct VMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Create, run and control the VM.",
        subcommands: [Create.self, Show.self, Set.self, Run.self, Status.self, Pause.self, Resume.self, Restart.self,
                      Stop.self, Delete.self, Media.self, Firmware.self, Screendump.self, Open.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a VM (config, firmware vars, TPM state, disk).")
        @OptionGroup var vm: VMSelection
        @Option(help: "vCPUs (default: performance cores, max 8).") var cpus: Int?
        @Option(help: "Memory in MiB (default: min(8192, half of RAM)).") var memory: Int?
        @Option(help: "Disk size in GiB for a blank disk.") var disk = 64
        @Option(help: ArgumentHelp("Golden image to back the system disk (overlay).", valueName: "base.qcow2")) var base: String?
        @Option(help: "Network: user, vmnet-shared or none.") var network = "user"

        func run() async throws {
            guard let net = VMConfig.NetworkMode(rawValue: network) else {
                throw ValidationError("--network must be user, vmnet-shared or none")
            }
            var config = VMConfig(name: vm.name, diskSizeGiB: disk, network: net)
            if let cpus { config.cpuCount = cpus }
            if let memory { config.memoryMiB = memory }
            let files = try await vm.store().create(config, baseImage: base.map { URL(filePath: $0) })
            print("created VM '\(config.name)' at \(files.directory.path(percentEncoded: false))")
            printConfig(config)
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the VM's config and whether it is running.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            let config = try vm.store().load(vm.name)
            printConfig(config)
            if let remote = VMRemote.attach(vm.files) {
                print("running  QEMU pid \(remote.record.qemuPID), since \(remote.record.startedAt)")
            } else {
                print("running  no")
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the VM in the foreground until it stops.",
            discussion: """
            Ctrl-C asks Windows to shut down (ACPI power button); press it again to force it off.
            Attach installer media with --cdrom (Windows ISO) and --usb (writable images).
            Control it from another terminal with `vm status|pause|resume|stop`.
            """
        )
        @OptionGroup var vm: VMSelection
        @Flag(help: "No display (non-GL GPU device). Default is a QEMU window with GL.") var headless = false
        @Flag(help: "No window: export the scanouts as IOSurfaces (-display seemless) for `seemlessctl screenshot` and `display`.")
        var exportDisplay = false
        @Option(help: ArgumentHelp("Attach an ISO read-only as a USB CD-ROM (repeatable, boot order).", valueName: "iso")) var cdrom: [String] = []
        @Option(help: ArgumentHelp("Attach a raw image read-write as a USB disk (repeatable).", valueName: "img")) var usb: [String] = []
        @Flag(help: "Start with vCPUs paused; resume with `vm resume`.") var paused = false
        @Option(help: ArgumentHelp("Write the guest's serial port to this file.", valueName: "file")) var serialLog: String?
        @Flag(help: "Press Escape during boot to open the UEFI firmware menu.") var firmwareSetup = false
        @Flag(help: "Press Space during boot to answer \"Press any key to boot from CD\".") var cdPrompt = false

        func validate() throws {
            if firmwareSetup && cdPrompt { throw ValidationError("--firmware-setup and --cd-prompt are exclusive") }
            if headless && exportDisplay { throw ValidationError("--headless and --export-display are exclusive") }
        }

        func run() async throws {
            let stack = try vm.stack()
            let store = VMStore(layout: vm.layout, stack: stack)
            let config = try store.load(vm.name)
            var drives: [RemovableDrive] = []
            for (i, path) in cdrom.enumerated() { drives.append(try drive("cd\(i)", path, cdrom: true)) }
            for (i, path) in usb.enumerated() { drives.append(try drive("usb\(i)", path, cdrom: false)) }
            let keys: BootKeys? = firmwareSetup ? .firmwareSetup : cdPrompt ? .cdPrompt : nil
            let display: LaunchOptions.Display = headless ? .headless : exportDisplay ? .exported : .cocoaWindow
            let options = LaunchOptions(display: display, removableDrives: drives,
                                        startPaused: true, serialLog: serialLog.map { URL(filePath: $0) },
                                        bootKeys: keys)
            let runDir = vm.layout.runDirectory(pid: getpid())
            let process = VMProcess(config: config, stack: stack, files: store.files(for: vm.name),
                                    options: options, runDirectory: runDir)

            let stopper = SignalStopper(process)
            let watcher = Task {
                for await state in process.states { print("state: \(state)") }
            }
            try await process.start(resume: !paused)
            print("QEMU pid \(await process.qemuPID ?? 0); QMP \(RunPaths(directory: runDir).controlSocket.path(percentEncoded: false))")
            await process.waitForExitIndefinitely()
            stopper.cancel()
            watcher.cancel()
            if case .crashed(let why) = await process.state {
                throw ValidationError("VM crashed: \(why) (logs: \(store.files(for: vm.name).logs.path(percentEncoded: false)))")
            }
        }

        func drive(_ id: String, _ path: String, cdrom: Bool) throws -> RemovableDrive {
            let url = URL(filePath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw ValidationError("not found: \(path)")
            }
            return RemovableDrive(id: id, file: url, isCDROM: cdrom)
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a stopped VM's settings.",
            discussion: "A bigger --disk grows the disk image; Windows still has to extend its partition. Disks cannot shrink.")
        @OptionGroup var vm: VMSelection
        @Option(help: "vCPUs.") var cpus: Int?
        @Option(help: "Memory in MiB.") var memory: Int?
        @Option(help: "Disk size in GiB (grow only).") var disk: Int?
        @Option(help: "Network: user, vmnet-shared or none.") var network: String?
        @Option(help: "Graphics backend: dxmt or d3dmetal.") var graphics: String?
        @Option(help: "Boot order: disk-first or removable-first.") var bootOrder: String?
        @Option(help: "TPM 2.0: on or off (Windows 11 needs it).") var tpm: String?
        @Option(help: "Seconds the firmware waits for a key (0-30).") var firmwareTimeout: Int?
        @Option(help: ArgumentHelp("Port forward proto:host:guest, e.g. tcp:3389:3389 (repeatable; replaces the list).", valueName: "fwd"))
        var forward: [String] = []
        @Flag(help: "Remove all port forwards.") var clearForwards = false

        func run() async throws {
            let manager = VMManager(layout: vm.layout, stack: try vm.stack())
            var c = try manager.store.load(vm.name)
            if let cpus { c.cpuCount = cpus }
            if let memory { c.memoryMiB = memory }
            if let disk { c.diskSizeGiB = disk }
            if let network {
                guard let n = VMConfig.NetworkMode(rawValue: network) else { throw ValidationError("--network must be user, vmnet-shared or none") }
                c.network = n
            }
            if let graphics {
                guard let g = VMConfig.GraphicsBackend(rawValue: graphics) else { throw ValidationError("--graphics must be dxmt or d3dmetal") }
                c.graphicsBackend = g
            }
            if let bootOrder {
                guard let o = VMConfig.BootSettings.Order(rawValue: bootOrder) else { throw ValidationError("--boot-order must be disk-first or removable-first") }
                c.boot.order = o
            }
            if let tpm {
                guard tpm == "on" || tpm == "off" else { throw ValidationError("--tpm must be on or off") }
                c.boot.tpm = tpm == "on"
            }
            if let firmwareTimeout { c.boot.firmwareTimeoutSeconds = firmwareTimeout }
            if clearForwards { c.portForwards = [] }
            if !forward.isEmpty { c.portForwards = try forward.map(parseForward) }
            try await manager.update(c)
            printConfig(c)
        }

        func parseForward(_ s: String) throws -> VMConfig.PortForward {
            let parts = s.split(separator: ":").map(String.init)
            guard parts.count == 3, let proto = VMConfig.PortForward.Proto(rawValue: parts[0]),
                  let host = UInt16(parts[1]), let guest = UInt16(parts[2]) else {
                throw ValidationError("--forward must look like tcp:3389:3389")
            }
            return .init(proto: proto, hostPort: host, guestPort: guest)
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hard-reset the running VM (reset button; Windows is not asked).")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            try await vm.remote().reset()
            print("reset")
        }
    }

    struct Media: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Media attached to the VM on every start (USB CD-ROM or disk).",
            subcommands: [List.self, Attach.self, Detach.self], defaultSubcommand: List.self)

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List attached media.")
            @OptionGroup var vm: VMSelection
            func run() async throws {
                let c = try vm.store().load(vm.name)
                if c.media.isEmpty { print("no media attached") }
                for m in c.media { print("\(m.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(m.path)\(m.exists ? "" : "  (missing)")") }
            }
        }

        struct Attach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Attach a file (.iso = CD-ROM, else writable disk).")
            @OptionGroup var vm: VMSelection
            @Argument(help: "ISO or raw image.") var file: String
            @Flag(help: "Attach as a writable disk even if it is an .iso.") var asDisk = false
            func run() async throws {
                let manager = VMManager(layout: vm.layout, stack: try vm.stack())
                let c = try await manager.attachMedia(vm.name, file: URL(filePath: file), kind: asDisk ? .disk : nil)
                print("attached; media now: \(c.media.map(\.path).joined(separator: ", "))")
            }
        }

        struct Detach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Detach a file.")
            @OptionGroup var vm: VMSelection
            @Argument(help: "Path as shown by `vm media list`.") var file: String
            func run() async throws {
                let manager = VMManager(layout: vm.layout, stack: try vm.stack())
                let path = URL(filePath: file).standardizedFileURL.path(percentEncoded: false)
                _ = try await manager.detachMedia(vm.name, path: path)
                print("detached")
            }
        }
    }

    struct Firmware: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset UEFI variables or TPM state of a stopped VM.",
            subcommands: [ResetVars.self, ResetTPM.self])

        struct ResetVars: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "reset-vars", abstract: "Blank UEFI variable store (boot entries, firmware settings).")
            @OptionGroup var vm: VMSelection
            @Flag(help: "Required confirmation.") var yes = false
            func run() async throws {
                guard yes else { throw ValidationError("this clears boot entries and firmware settings; pass --yes") }
                try await VMManager(layout: vm.layout, stack: try vm.stack()).resetFirmwareVariables(vm.name)
                print("UEFI variables reset")
            }
        }

        struct ResetTPM: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "reset-tpm", abstract: "Clear the TPM (BitLocker keys and Windows Hello PINs are lost).")
            @OptionGroup var vm: VMSelection
            @Flag(help: "Required confirmation.") var yes = false
            func run() async throws {
                guard yes else { throw ValidationError("this clears the TPM; pass --yes") }
                try await VMManager(layout: vm.layout, stack: try vm.stack()).resetTPM(vm.name)
                print("TPM cleared")
            }
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a Windows installer (.exe/.msi) from the Mac inside the running VM.",
            discussion: """
            Hot-plugs a read-only USB drive labelled SLRUN with the installer. VMs installed by \
            `image build` start it by themselves once a user is logged on; older VMs show the drive \
            in File Explorer (run "Enable automatic installs.cmd" on it once).
            """)
        @OptionGroup var vm: VMSelection
        @Argument(help: "Installer on the Mac.") var installer: String
        func run() async throws {
            let manager = VMManager(layout: vm.layout, stack: try vm.stack())
            let request = try await manager.launch(vm.name, installer: URL(filePath: installer).standardizedFileURL,
                                                   assets: ImageAssets.locate())
            print("sent \(request.fileName) (request \(request.id.prefix(8)))")
        }
    }

    struct Screendump: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save the VM's current screen as PNG (QMP screendump; QEMU's view, before the app's display path exists).")
        @OptionGroup var vm: VMSelection
        @Option(help: "Output PNG.") var out: String
        func run() async throws {
            let qmp = try await vm.remote().connect()
            defer { Task { await qmp.close() } }
            let path = URL(filePath: out).standardizedFileURL.path(percentEncoded: false)
            try await qmp.execute("screendump", arguments: ["filename": .string(path), "format": "png"])
            print(path)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the running VM's state.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            guard let remote = VMRemote.attach(vm.files) else { print("stopped"); return }
            let qmp = try await remote.connect()
            defer { Task { await qmp.close() } }
            let status = try await qmp.queryStatus()
            print("\(status.state) (QEMU pid \(remote.record.qemuPID))")
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause the VM's vCPUs.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            let qmp = try await vm.remote().connect()
            try await qmp.stop()
            await qmp.close()
            print("paused")
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume a paused VM.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            let qmp = try await vm.remote().connect()
            try await qmp.cont()
            await qmp.close()
            print("running")
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shut the VM down (guest shutdown, then forced).")
        @OptionGroup var vm: VMSelection
        @Option(help: "Seconds to wait for Windows to shut down before forcing it off.") var timeout = 60
        @Flag(help: "Power off immediately without asking Windows.") var force = false
        func run() async throws {
            let how = try await vm.remote().stop(graceful: force ? .zero : .seconds(timeout))
            print("stopped (\(how.rawValue))")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a stopped VM and its disk, firmware and TPM state.")
        @OptionGroup var vm: VMSelection
        @Flag(help: "Required: confirms that the disk and everything on it is deleted.") var yes = false
        func run() async throws {
            guard yes else { throw ValidationError("this deletes the VM's disk permanently; pass --yes to confirm") }
            try vm.store().delete(vm.name)
            print("deleted VM '\(vm.name)'")
        }
    }
}

// MARK: - image

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Inspect Windows media and run the unattended install (docs/03).",
        subcommands: [Inspect.self, Build.self, Payload.self, Result.self]
    )

    static func assets() throws -> ImageAssets {
        guard let a = ImageAssets.locate() else {
            throw ValidationError("image assets not found: set SEEMLESS_IMAGE_ASSETS or run from the repository")
        }
        return a
    }

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the editions on a Windows ISO and whether each is supported.")
        @Argument(help: "Windows 11 ARM64 ISO.") var iso: String
        func run() async throws {
            let inspection = try await ISOMedia.inspect(URL(filePath: iso))
            print("install image  \(inspection.installImagePath) (\(inspection.wim.imageCount) images)")
            for image in inspection.wim.images {
                let ok = image.isSupported ? "ok " : "NO "
                print("\(ok) \(String(image.index).padding(toLength: 3, withPad: " ", startingAt: 0)) \(image.name)  [\(image.architecture), \(image.major).\(image.minor).\(image.build).\(image.spBuild), \(image.languages.joined(separator: ","))]")
                for reason in image.unsupportedReasons { print("      - \(reason)") }
            }
            if let p = inspection.wim.preferredImage { print("default edition: index \(p.index) (\(p.name))") }
        }
    }

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a VM and install Windows into it unattended from an ISO.",
            discussion: """
            Boots the ISO's Windows Setup with a generated payload disk; apply.cmd installs Windows with DISM, \
            Windows finishes setup, then the VM powers off. Logs, DISM inventories and status are copied to \
            the VM's logs/image-build-<time>/ folder.

            Microsoft's licence page is shown during setup for you to accept in the VM window, unless you pass \
            --accept-windows-license, which states that you have read and accept Microsoft's licence terms.

            Untested until spike S4 (docs/09): expect to debug the first runs with the window open.
            """
        )
        @OptionGroup var vm: VMSelection
        @Option(help: "Windows 11 ARM64 ISO.") var iso: String
        @Option(help: "Edition index from `image inspect` (default: Pro).") var edition: Int?
        @Option(help: "Windows account name.") var user = "Seemless"
        @Option(help: "Recipe under image/recipes: seemless-default (Lean), seemless-gaming (Lean, with Xbox) or stock (Fat, nothing removed).") var recipe = "seemless-default"
        @Option(help: "vCPUs.") var cpus: Int?
        @Option(help: "Memory in MiB.") var memory: Int?
        @Option(help: "Disk size in GiB.") var disk = 64
        @Option(help: "Minutes to wait before forcing the VM off.") var timeout = 120
        @Option(help: ArgumentHelp("Folder of ARM64 drivers (.inf) to inject.", valueName: "dir")) var drivers: String?
        @Option(help: ArgumentHelp("Folder of guest agent files to copy in.", valueName: "dir")) var agent: String?
        @Flag(help: "Turn on Windows test signing (for test-signed drivers; docs/01 D12).") var testSigning = false
        @Flag(help: "No window (you cannot see or answer Windows' licence page).") var headless = false
        @Flag(name: .customLong("accept-windows-license"),
              help: "I have read and accept Microsoft's Windows licence terms; skip the licence page.") var acceptLicense = false

        func validate() throws {
            if headless && !acceptLicense {
                throw ValidationError("--headless needs --accept-windows-license: without a window nobody can accept the licence page")
            }
        }

        func run() async throws {
            var config = VMConfig(name: vm.name, diskSizeGiB: disk)
            if let cpus { config.cpuCount = cpus }
            if let memory { config.memoryMiB = memory }
            var request = ImageBuilder.Request(iso: URL(filePath: iso).standardizedFileURL, vm: config)
            request.imageIndex = edition
            request.username = user
            request.recipe = recipe
            request.acceptWindowsLicense = acceptLicense
            request.display = headless ? .headless : .cocoaWindow
            request.timeout = .seconds(timeout * 60)
            request.drivers = drivers.map { URL(filePath: $0, directoryHint: .isDirectory) }
            request.agent = agent.map { URL(filePath: $0, directoryHint: .isDirectory) }
            request.testSigning = testSigning

            let builder = ImageBuilder(layout: vm.layout, stack: try vm.stack(), assets: try ImageCommand.assets())
            let report = try await builder.build(request) { line in
                print("[\(Date().formatted(date: .omitted, time: .standard))] \(line)")
            }
            print("")
            print("status   \(report.result.status ?? "none (apply.cmd never ran: did WinPE boot and find autounattend.xml?)")")
            print("results  \(report.resultDirectory.path(percentEncoded: false)) (\(report.result.files.joined(separator: ", ")))")
            print("elapsed  \(report.elapsed.formatted(.units(allowed: [.minutes, .seconds])))\(report.timedOut ? " (timed out)" : "")")
            if report.result.succeeded {
                print("Windows is installed. Start it with: seemlessctl vm run --name \(vm.name)")
            } else {
                throw ExitCode(1)
            }
        }
    }

    struct Payload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a payload disk without running anything (for inspection).")
        @Option(help: "Output raw disk image.") var out: String
        @Option(help: "Edition index.") var edition = 6
        @Option(help: "Recipe under image/recipes.") var recipe = "seemless-default"
        @Flag(name: .customLong("accept-windows-license"), help: "Same meaning as for `image build`.") var acceptLicense = false
        func run() async throws {
            let settings = SetupPayload.Settings(imageIndex: edition, password: WindowsCredentials.generatePassword(),
                                                 timeZone: WindowsTimeZone.current, hideLicensePage: acceptLicense,
                                                 recipeName: recipe)
            try await SetupPayload(assets: try ImageCommand.assets(), settings: settings)
                .writeDiskImage(to: URL(filePath: out))
            print("wrote \(out) (throwaway password; not stored)")
        }
    }

    struct Result: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read the results a guest left on a VM's payload disk.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            try vm.requireStopped()
            let image = vm.files.directory.appending(path: "setup-payload.img")
            let dest = vm.files.logs.appending(path: "image-build-reread", directoryHint: .isDirectory)
            let r = try await SetupPayload.collectResult(from: image, into: dest)
            print("status   \(r.status ?? "none")")
            print("results  \(dest.path(percentEncoded: false)) (\(r.files.joined(separator: ", ")))")
        }
    }
}

// MARK: - disk

struct DiskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk",
        abstract: "Inspect and manage the VM's system disk (VM must be stopped to modify).",
        subcommands: [Info.self, Snapshot.self, Reset.self, Resize.self]
    )

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show size, backing image and snapshots.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            let info = try await DiskTool(stack: vm.stack()).info(vm.files.systemDisk)
            print("disk      \(vm.files.systemDisk.path(percentEncoded: false))")
            print("format    \(info.format)")
            print("virtual   \(gib(info.virtualSize))")
            print("on disk   \(gib(info.actualSize))")
            print("backing   \(info.backingFile ?? "none")")
            print("snapshots \(info.snapshots.isEmpty ? "none" : info.snapshots.map(\.name).joined(separator: ", "))")
        }
    }

    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Offline snapshots of the system disk.")
        @OptionGroup var vm: VMSelection
        @Argument(help: "list, create, apply or delete.") var action: String
        @Argument(help: "Snapshot name.") var snapshot: String?

        func run() async throws {
            let disks = try DiskTool(stack: vm.stack())
            let disk = vm.files.systemDisk
            if action == "list" {
                for s in try await disks.info(disk).snapshots { print("\(s.name)\t\(s.date)") }
                return
            }
            try vm.requireStopped()
            guard let snapshot else { throw ValidationError("\(action) needs a snapshot name") }
            switch action {
            case "create": try await disks.createSnapshot(disk, name: snapshot)
            case "apply": try await disks.applySnapshot(disk, name: snapshot)
            case "delete": try await disks.deleteSnapshot(disk, name: snapshot)
            default: throw ValidationError("action must be list, create, apply or delete")
            }
            print("\(action) \(snapshot): done")
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard all changes since the golden image (overlay disks only).")
        @OptionGroup var vm: VMSelection
        @Flag(help: "Required: confirms that everything written to Windows since the image is lost.") var yes = false
        func run() async throws {
            guard yes else { throw ValidationError("this discards all changes inside Windows; pass --yes to confirm") }
            try vm.requireStopped()
            try await DiskTool(stack: vm.stack()).resetOverlay(vm.files.systemDisk)
            print("disk reset to its base image")
        }
    }

    struct Resize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Grow the system disk (extend the partition inside Windows afterwards).")
        @OptionGroup var vm: VMSelection
        @Argument(help: "New size in GiB.") var gib: Int
        func run() async throws {
            try vm.requireStopped()
            try await DiskTool(stack: vm.stack()).resize(vm.files.systemDisk, toGiB: gib)
            var config = try vm.store().load(vm.name)
            config.diskSizeGiB = gib
            try vm.store().save(config)
            print("disk is now \(gib) GiB")
        }
    }
}

// MARK: - stack, paths

struct StackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stack", abstract: "Check the host stack (QEMU, swtpm, firmware).")
    func run() async throws {
        guard let stack = HostStack.locate() else {
            throw ValidationError("not found: set SEEMLESS_PREFIX or run scripts/build-deps.sh all")
        }
        print("prefix   \(stack.prefix.path(percentEncoded: false))")
        let missing = stack.missingFiles()
        print("complete \(missing.isEmpty ? "yes" : "NO, missing: " + missing.joined(separator: ", "))")
        if missing.isEmpty {
            let v = try await ProcessRunner.run(stack.qemu, ["--version"])
            print("qemu     \(v.stdoutString.split(separator: "\n").first ?? "")")
        }
    }
}

/// `seemlessctl paths`: print the host storage layout (docs/02).
struct Paths: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print where Seemless stores images, VMs, caches and sockets."
    )

    func run() throws {
        let layout = StorageLayout.default
        let rows: [(String, URL)] = [
            ("root", layout.root),
            ("images", layout.images),
            ("vm", layout.vm()),
            ("cache", layout.cache),
            ("run", layout.run),
        ]
        for (name, url) in rows {
            print("\(name.padding(toLength: 7, withPad: " ", startingAt: 0)) \(url.path(percentEncoded: false))")
        }
    }
}

// MARK: - helpers

func printConfig(_ c: VMConfig) {
    print("name     \(c.name)")
    print("cpus     \(c.cpuCount)")
    print("memory   \(c.memoryMiB) MiB")
    print("disk     \(c.diskSizeGiB) GiB")
    print("network  \(c.network.rawValue)\(c.portForwards.isEmpty ? "" : ", forwards " + c.portForwards.map { "\($0.proto.rawValue) \($0.hostPort)->\($0.guestPort)" }.joined(separator: ", "))")
    print("graphics \(c.graphicsBackend.rawValue)")
    print("mac      \(c.macAddress)")
    print("boot     \(c.boot.order.rawValue), tpm \(c.boot.tpm ? "on" : "off"), firmware wait \(c.boot.firmwareTimeoutSeconds) s")
    for m in c.media { print("media    \(m.kind.rawValue) \(m.path)\(m.exists ? "" : " (missing)")") }
}

func gib(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

/// First Ctrl-C (or SIGTERM): graceful stop. Second: force.
final class SignalStopper: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private var count = 0

    init(_ process: VMProcess) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [self] in
                count += 1
                let force = count > 1
                FileHandle.standardError.write(Data((force ? "\nforcing off...\n" : "\nshutting down (Ctrl-C again to force)...\n").utf8))
                Task { await process.stop(graceful: force ? .zero : .seconds(60)) }
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() { sources.forEach { $0.cancel() } }
}
