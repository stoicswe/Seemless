import Foundation

/// Where the host-stack binaries live (`build/prefix` in development, inside
/// the app bundle later).
public struct HostStack: Sendable, Equatable {
    public var prefix: URL

    public init(prefix: URL) { self.prefix = prefix }

    public var qemu: URL { prefix.appending(path: "bin/qemu-system-aarch64") }
    public var qemuImg: URL { prefix.appending(path: "bin/qemu-img") }
    public var swtpm: URL { prefix.appending(path: "bin/swtpm") }
    public var firmwareCode: URL { prefix.appending(path: "share/qemu/edk2-aarch64-code.fd") }
    public var libDirectory: URL { prefix.appending(path: "lib") }
    public var angleLibDirectory: URL { prefix.appending(path: "ANGLE.xcarchive/Products/usr/local/lib") }

    /// Finds the stack: `$SEEMLESS_PREFIX`, else `build/prefix` in the
    /// repository containing the running executable or the current directory.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> HostStack? {
        if let explicit = environment["SEEMLESS_PREFIX"], !explicit.isEmpty {
            return HostStack(prefix: URL(filePath: explicit, directoryHint: .isDirectory))
        }
        let starts = [
            URL(filePath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent(),
            URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        ]
        for start in starts {
            var dir = start
            for _ in 0..<8 {
                let candidate = HostStack(prefix: dir.appending(path: "build/prefix", directoryHint: .isDirectory))
                if FileManager.default.isExecutableFile(atPath: candidate.qemu.path(percentEncoded: false)) {
                    return candidate
                }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    /// Missing files, as paths. Empty when the stack is usable.
    public func missingFiles() -> [String] {
        [qemu, qemuImg, swtpm, firmwareCode]
            .map { $0.path(percentEncoded: false) }
            .filter { !FileManager.default.fileExists(atPath: $0) }
    }
}

/// A removable drive attached as USB mass storage (Windows media, the setup
/// payload, guest tools). Windows' inbox USB storage driver works in WinPE.
public struct RemovableDrive: Sendable, Equatable {
    public var id: String
    public var file: URL
    public var isCDROM: Bool

    public init(id: String, file: URL, isCDROM: Bool = true) {
        self.id = id
        self.file = file
        self.isCDROM = isCDROM
    }
}

/// Per-launch choices that are not part of the persisted config.
public struct LaunchOptions: Sendable, Equatable {
    public enum Display: Sendable, Equatable {
        /// No display. Uses the non-GL GPU device, because virtio-gpu-gl
        /// refuses to start without a GL display (S1). For tests and
        /// headless image builds.
        case headless
        /// QEMU's own Cocoa window with GL via ANGLE/Metal. Bring-up mode
        /// until the app's display path exists (S3).
        case cocoaWindow
        /// No window: scanouts are exported as IOSurfaces by our `ui/seemless`
        /// backend (patches/qemu/0001, docs/04) for `DisplayClient`
        /// (`seemlessctl screenshot`, later the app's renderer, WP3.2).
        case exported
    }

    public var display: Display
    /// Removable media, in boot-priority order.
    public var removableDrives: [RemovableDrive]
    /// Start with vCPUs paused (`-S`); the caller sends `cont` over QMP.
    public var startPaused: Bool
    /// File that receives the guest's first serial port (WinPE progress, docs/03).
    public var serialLog: URL?
    /// Keys pressed for the first seconds after the vCPUs start (see `BootKeys`).
    public var bootKeys: BootKeys?

    public init(
        display: Display = .cocoaWindow,
        removableDrives: [RemovableDrive] = [],
        startPaused: Bool = true,
        serialLog: URL? = nil,
        bootKeys: BootKeys? = nil
    ) {
        self.display = display
        self.removableDrives = removableDrives
        self.startPaused = startPaused
        self.serialLog = serialLog
        self.bootKeys = bootKeys
    }
}

/// Socket and state files for one launch. Paths are kept short because
/// `sun_path` is limited to 104 bytes (docs/02).
public struct RunPaths: Sendable, Equatable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// QMP for the process that owns the VM (`VMProcess`).
    public var qmpSocket: URL { directory.appending(path: "qmp.sock") }
    /// Second QMP monitor for other controllers (`VMRemote`, a second
    /// `seemlessctl`). QEMU serves one client per monitor, so the owner's
    /// connection would otherwise lock everyone else out.
    public var controlSocket: URL { directory.appending(path: "ctl.sock") }
    /// Third QMP monitor, held by Zen mode for guest input (`input-send-event`)
    /// for as long as it runs, so it never locks `VMRemote` out of `ctl.sock`.
    public var inputSocket: URL { directory.appending(path: "input.sock") }
    public var agentSocket: URL { directory.appending(path: "agent.sock") }
    public var bulkSocket: URL { directory.appending(path: "bulk.sock") }
    public var swtpmSocket: URL { directory.appending(path: "swtpm.sock") }
    public var qemuLog: URL { directory.appending(path: "qemu.log") }
    public var swtpmLog: URL { directory.appending(path: "swtpm.log") }

    public var sockets: [URL] { [qmpSocket, controlSocket, inputSocket, agentSocket, bulkSocket, swtpmSocket] }
}

/// Files that belong to one VM on disk (docs/02 storage layout).
public struct VMFiles: Sendable, Equatable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public var config: URL { directory.appending(path: "config.json") }
    public var systemDisk: URL { directory.appending(path: "system.qcow2") }
    public var efiVars: URL { directory.appending(path: "efi_vars.fd") }
    public var tpmState: URL { directory.appending(path: "tpm", directoryHint: .isDirectory) }
    public var logs: URL { directory.appending(path: "logs", directoryHint: .isDirectory) }
    /// Present while a VM process is running; see `RunningVM`.
    public var runningRecord: URL { directory.appending(path: "running.json") }
}

/// Builds the QEMU argument list and environment. This is the single place
/// that encodes docs/02's "Baseline command line"; `QEMUCommandTests` pins it.
public struct QEMUCommand: Sendable {
    public var config: VMConfig
    public var stack: HostStack
    public var files: VMFiles
    public var run: RunPaths
    public var options: LaunchOptions

    public init(config: VMConfig, stack: HostStack, files: VMFiles, run: RunPaths, options: LaunchOptions) {
        self.config = config
        self.stack = stack
        self.files = files
        self.run = run
        self.options = options
    }

    /// The VM's persisted media (`VMConfig.media`, ids `m0`, `m1`, ...)
    /// followed by this launch's extra drives, in boot-priority order.
    public var removableDrives: [RemovableDrive] {
        let persisted = config.media.enumerated().map { i, m in
            RemovableDrive(id: "m\(i)", file: m.url, isCDROM: m.kind == .cdrom)
        }
        return persisted + options.removableDrives
    }

    /// Virtio-serial port names the guest agent opens (docs/06).
    public static let agentPortName = "app.seemless.agent.0"
    public static let bulkPortName = "app.seemless.bulk.0"

    public var arguments: [String] {
        let p = { (url: URL) in url.path(percentEncoded: false) }
        var a: [String] = []
        a += ["-name", "seemless-\(config.name)", "-nodefaults", "-no-user-config"]
        a += ["-machine", "virt,highmem=on"]
        a += ["-accel", "hvf,ipa-granule-size=0x1000"]
        a += ["-cpu", "host"]
        a += ["-smp", "cpus=\(config.cpuCount),sockets=1,cores=\(config.cpuCount),threads=1"]
        a += ["-m", "\(config.memoryMiB)"]
        a += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(p(stack.firmwareCode))"]
        a += ["-drive", "if=pflash,format=raw,unit=1,file=\(p(files.efiVars))"]

        switch options.display {
        case .cocoaWindow:
            a += ["-device", "virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2"]
            a += ["-display", "cocoa,gl=es"]
        case .exported:
            a += ["-device", "virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2"]
            a += ["-display", "seemless,gl=es,service=\(DisplayExport.serviceName(for: run))"]
        case .headless:
            a += ["-device", "virtio-ramfb,max_outputs=2"]
            a += ["-display", "none"]
        }

        // Boot order is expressed with bootindex, which edk2 reads from
        // fw_cfg "bootorder" (lower first).
        let drives = removableDrives
        let removableFirst = config.boot.order == .removableFirst
        let diskIndex = removableFirst ? drives.count + 1 : 1
        a += ["-device", "nvme,drive=sys,serial=seemless0,bootindex=\(diskIndex)"]
        a += ["-drive", "if=none,id=sys,file=\(p(files.systemDisk)),format=qcow2,discard=unmap,cache=writethrough,aio=threads"]
        if config.boot.firmwareTimeoutSeconds > 0 {
            a += ["-boot", "menu=on,splash-time=\(config.boot.firmwareTimeoutSeconds * 1000)"]
        }

        a += ["-device", "qemu-xhci,id=usb"]
        a += ["-device", "usb-kbd,bus=usb.0", "-device", "usb-tablet,bus=usb.0"]
        for (i, drive) in drives.enumerated() {
            let media = drive.isCDROM ? ",media=cdrom,readonly=on" : ""
            let index = removableFirst ? i + 1 : i + 2
            a += ["-drive", "if=none,id=\(drive.id),file=\(p(drive.file)),format=raw\(media)"]
            a += ["-device", "usb-storage,bus=usb.0,drive=\(drive.id),removable=on,bootindex=\(index)"]
        }

        switch config.network {
        case .user:
            let forwards = config.portForwards
                .map { ",hostfwd=\($0.proto.rawValue):127.0.0.1:\($0.hostPort)-:\($0.guestPort)" }
                .joined()
            a += ["-netdev", "user,id=n0\(forwards)"]
            a += ["-device", "virtio-net-pci,netdev=n0,mac=\(config.macAddress)"]
        case .vmnetShared:
            a += ["-netdev", "vmnet-shared,id=n0"]
            a += ["-device", "virtio-net-pci,netdev=n0,mac=\(config.macAddress)"]
        case .none:
            break
        }

        a += ["-device", "virtio-serial-pci"]
        a += ["-chardev", "socket,id=agent,path=\(p(run.agentSocket)),server=on,wait=off"]
        a += ["-device", "virtserialport,chardev=agent,name=\(Self.agentPortName)"]
        a += ["-chardev", "socket,id=bulk,path=\(p(run.bulkSocket)),server=on,wait=off"]
        a += ["-device", "virtserialport,chardev=bulk,name=\(Self.bulkPortName)"]

        if config.boot.tpm {
            a += ["-chardev", "socket,id=tpm,path=\(p(run.swtpmSocket))"]
            a += ["-tpmdev", "emulator,id=tpm0,chardev=tpm", "-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        a += ["-audiodev", "coreaudio,id=a0", "-device", "usb-audio,bus=usb.0,audiodev=a0"]
        a += ["-rtc", "base=localtime"]
        if let serial = options.serialLog {
            a += ["-serial", "file:\(p(serial))"]
        }
        a += ["-qmp", "unix:\(p(run.qmpSocket)),server=on,wait=off"]
        a += ["-qmp", "unix:\(p(run.controlSocket)),server=on,wait=off"]
        a += ["-qmp", "unix:\(p(run.inputSocket)),server=on,wait=off"]
        if options.startPaused { a += ["-S"] }
        return a
    }

    /// Environment additions for the QEMU process (docs/02; S1 findings).
    public var environment: [String: String] {
        let p = { (url: URL) in url.path(percentEncoded: false) }
        return [
            "ANGLE_DEFAULT_PLATFORM": "metal",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(p(stack.libDirectory)):\(p(stack.angleLibDirectory))",
            // virglrenderer defaults to d3dmetal when this is unset, so it is
            // always set explicitly (render_worker.c).
            "NPT_BACKEND": config.graphicsBackend.rawValue,
        ]
    }

    /// swtpm arguments for this VM (TPM 2.0, state persisted per VM).
    public var swtpmArguments: [String] {
        let p = { (url: URL) in url.path(percentEncoded: false) }
        return [
            "socket", "--tpm2",
            "--tpmstate", "dir=\(p(files.tpmState))",
            "--ctrl", "type=unixio,path=\(p(run.swtpmSocket))",
            "--log", "file=\(p(run.swtpmLog)),level=5",
            "--terminate",
        ]
    }
}
