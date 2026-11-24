import Foundation
import Testing
@testable import SeemlessKit

@Suite struct QEMUCommandTests {
    static let host = HostInfo(performanceCores: 4, logicalCores: 8, memoryMiB: 24_576)

    func command(display: LaunchOptions.Display = .cocoaWindow,
                 drives: [RemovableDrive] = [],
                 config: VMConfig? = nil) -> QEMUCommand {
        let cfg = config ?? VMConfig(cpuCount: 4, memoryMiB: 8192, macAddress: "02:00:00:00:00:01")
        return QEMUCommand(
            config: cfg,
            stack: HostStack(prefix: URL(filePath: "/p", directoryHint: .isDirectory)),
            files: VMFiles(directory: URL(filePath: "/vm", directoryHint: .isDirectory)),
            run: RunPaths(directory: URL(filePath: "/r", directoryHint: .isDirectory)),
            options: LaunchOptions(display: display, removableDrives: drives, startPaused: true,
                                   serialLog: URL(filePath: "/r/serial.log"))
        )
    }

    /// Snapshot of the whole command line. If this changes, update docs/02's
    /// baseline in the same change.
    @Test func baselineMatchesDocs02() {
        let expected = """
        -name seemless-default
        -nodefaults
        -no-user-config
        -machine virt,highmem=on
        -accel hvf,ipa-granule-size=0x1000
        -cpu host
        -smp cpus=4,sockets=1,cores=4,threads=1
        -m 8192
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/p/share/qemu/edk2-aarch64-code.fd
        -drive if=pflash,format=raw,unit=1,file=/vm/efi_vars.fd
        -device virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2
        -display cocoa,gl=es
        -device nvme,drive=sys,serial=seemless0,bootindex=1
        -drive if=none,id=sys,file=/vm/system.qcow2,format=qcow2,discard=unmap,cache=writethrough,aio=threads
        -device qemu-xhci,id=usb
        -device usb-kbd,bus=usb.0
        -device usb-tablet,bus=usb.0
        -netdev user,id=n0
        -device virtio-net-pci,netdev=n0,mac=02:00:00:00:00:01
        -device virtio-serial-pci
        -chardev socket,id=agent,path=/r/agent.sock,server=on,wait=off
        -device virtserialport,chardev=agent,name=app.seemless.agent.0
        -chardev socket,id=bulk,path=/r/bulk.sock,server=on,wait=off
        -device virtserialport,chardev=bulk,name=app.seemless.bulk.0
        -chardev socket,id=tpm,path=/r/swtpm.sock
        -tpmdev emulator,id=tpm0,chardev=tpm
        -device tpm-tis-device,tpmdev=tpm0
        -audiodev coreaudio,id=a0
        -device usb-audio,bus=usb.0,audiodev=a0
        -rtc base=localtime
        -serial file:/r/serial.log
        -qmp unix:/r/qmp.sock,server=on,wait=off
        -qmp unix:/r/ctl.sock,server=on,wait=off
        -qmp unix:/r/input.sock,server=on,wait=off
        -S
        """
        #expect(Self.render(command().arguments) == expected)
    }

    @Test func headlessUsesNonGLDevice() {
        let args = command(display: .headless).arguments
        #expect(args.contains("virtio-ramfb,max_outputs=2"))
        #expect(!args.joined(separator: " ").contains("-gl"))
        #expect(args.contains("none"))
    }

    @Test func removableDrivesBootAfterSystemDisk() {
        let args = command(drives: [
            RemovableDrive(id: "win", file: URL(filePath: "/isos/win.iso")),
            RemovableDrive(id: "payload", file: URL(filePath: "/r/setup.img"), isCDROM: false),
        ]).arguments.joined(separator: " ")
        #expect(args.contains("-drive if=none,id=win,file=/isos/win.iso,format=raw,media=cdrom,readonly=on"))
        #expect(args.contains("-device usb-storage,bus=usb.0,drive=win,removable=on,bootindex=2"))
        #expect(args.contains("-drive if=none,id=payload,file=/r/setup.img,format=raw -device"))
        #expect(args.contains("drive=payload,removable=on,bootindex=3"))
    }

    @Test func portForwardsBindLoopbackOnly() {
        var cfg = VMConfig(cpuCount: 2, memoryMiB: 4096, macAddress: "02:00:00:00:00:01")
        cfg.portForwards = [.init(hostPort: 3389, guestPort: 3389), .init(proto: .udp, hostPort: 5000, guestPort: 50)]
        let args = command(config: cfg).arguments
        #expect(args.contains("user,id=n0,hostfwd=tcp:127.0.0.1:3389-:3389,hostfwd=udp:127.0.0.1:5000-:50"))
    }

    @Test func noNetworkOmitsNIC() {
        var cfg = VMConfig(cpuCount: 2, memoryMiB: 4096, macAddress: "02:00:00:00:00:01")
        cfg.network = .none
        #expect(!command(config: cfg).arguments.joined(separator: " ").contains("netdev"))
    }

    @Test func environmentAlwaysSetsNeptuneBackend() {
        #expect(command().environment["NPT_BACKEND"] == "dxmt")
        var cfg = VMConfig(cpuCount: 2, memoryMiB: 4096, macAddress: "02:00:00:00:00:01")
        cfg.graphicsBackend = .d3dmetal
        #expect(command(config: cfg).environment["NPT_BACKEND"] == "d3dmetal")
        #expect(command().environment["ANGLE_DEFAULT_PLATFORM"] == "metal")
        #expect(command().environment["NPT_D3D12_LIBRARY_PATH"] == "/p/lib/libvkd3d-proton-d3d12.dylib")
        #expect(command(config: cfg).environment["NPT_D3D12_LIBRARY_PATH"] == nil)
        #expect(command().environment["VKD3D_SHADER_CACHE_PATH"]?.hasSuffix("/shader-cache/") == true)
        #expect(command().environment["DYLD_FALLBACK_LIBRARY_PATH"] == "/p/lib:/p/ANGLE.xcarchive/Products/usr/local/lib")
    }

    @Test func swtpmUsesPerVMStateAndRunSocket() {
        let args = command().swtpmArguments.joined(separator: " ")
        #expect(args == "socket --tpm2 --tpmstate dir=/vm/tpm/ --ctrl type=unixio,path=/r/swtpm.sock --log file=/r/swtpm.log,level=5 --terminate")
    }

    /// One option and its value per line, for a readable snapshot.
    static func render(_ args: [String]) -> String {
        var lines: [String] = []
        var i = 0
        while i < args.count {
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                lines.append("\(args[i]) \(args[i + 1])"); i += 2
            } else {
                lines.append(args[i]); i += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}

@Suite struct VMConfigTests {
    let host = HostInfo(performanceCores: 4, logicalCores: 8, memoryMiB: 24_576)

    @Test func defaultsFollowDocs02() {
        #expect(host.defaultVCPUs == 4)
        #expect(host.defaultMemoryMiB == 8192)
        #expect(HostInfo(performanceCores: 12, logicalCores: 16, memoryMiB: 65_536).defaultVCPUs == 8)
        #expect(HostInfo(performanceCores: 4, logicalCores: 8, memoryMiB: 8192).defaultMemoryMiB == 4096)
    }

    @Test func validConfigHasNoErrors() {
        let cfg = VMConfig(cpuCount: 4, memoryMiB: 8192, macAddress: "02:00:00:00:00:01")
        #expect(cfg.validationErrors(host: host).isEmpty)
    }

    @Test func rejectsBadValues() {
        let cfg = VMConfig(name: "../x", cpuCount: 99, memoryMiB: 2048, diskSizeGiB: 8,
                           portForwards: [.init(hostPort: 1, guestPort: 1), .init(hostPort: 1, guestPort: 2)],
                           macAddress: "nope")
        #expect(cfg.validationErrors(host: host).count == 6)
    }

    @Test func randomMACIsLocallyAdministeredUnicast() {
        for _ in 0..<20 {
            let mac = VMConfig.randomMAC()
            #expect(mac.hasPrefix("02:"))
            #expect(VMConfig(cpuCount: 1, memoryMiB: 4096, macAddress: mac).validationErrors(host: host).isEmpty)
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let cfg = VMConfig(cpuCount: 4, memoryMiB: 8192, network: .vmnetShared,
                           portForwards: [.init(hostPort: 8080, guestPort: 80)], macAddress: "02:00:00:00:00:01")
        let data = try JSONEncoder().encode(cfg)
        #expect(try JSONDecoder().decode(VMConfig.self, from: data) == cfg)
    }
}

@Suite struct VMStateTests {
    /// Regression: description used to recurse through String(describing:).
    @Test func descriptionsAreReadable() {
        let all: [VMProcess.State] = [.stopped, .starting, .running, .paused, .stopping, .crashed("exit 1")]
        #expect(all.map(\.description) == ["stopped", "starting", "running", "paused", "stopping", "crashed (exit 1)"])
    }
}

/// Release app bundle layout (WP8.1).
@Suite struct HostStackBundleTests {
    func bundleCommand() -> QEMUCommand {
        QEMUCommand(
            config: VMConfig(cpuCount: 4, memoryMiB: 8192, macAddress: "02:00:00:00:00:01"),
            stack: .appBundle(URL(filePath: "/A/Seemless.app", directoryHint: .isDirectory)),
            files: VMFiles(directory: URL(filePath: "/vm", directoryHint: .isDirectory)),
            run: RunPaths(directory: URL(filePath: "/r", directoryHint: .isDirectory)),
            options: LaunchOptions(display: .headless))
    }

    @Test func bundlePaths() {
        let s = HostStack.appBundle(URL(filePath: "/A/Seemless.app", directoryHint: .isDirectory))
        #expect(s.qemu.path(percentEncoded: false) == "/A/Seemless.app/Contents/Helpers/qemu-system-aarch64")
        #expect(s.swtpm.path(percentEncoded: false) == "/A/Seemless.app/Contents/Helpers/swtpm")
        #expect(s.firmwareCode.path(percentEncoded: false) == "/A/Seemless.app/Contents/Resources/qemu/edk2-aarch64-code.fd")
        #expect(s.d3d12Library.path(percentEncoded: false) == "/A/Seemless.app/Contents/Frameworks/libvkd3d-proton-d3d12.dylib")
    }

    @Test func bundlePassesDataDirAndNoDyldVariables() {
        let cmd = bundleCommand()
        let args = cmd.arguments
        let l = args.firstIndex(of: "-L")
        #expect(l != nil && args[l! + 1] == "/A/Seemless.app/Contents/Resources/qemu")
        #expect(cmd.environment["DYLD_FALLBACK_LIBRARY_PATH"] == nil)
        #expect(cmd.environment["RENDER_SERVER_EXEC_PATH"] == "/A/Seemless.app/Contents/Helpers/virgl_render_server")
    }

    @Test func prefixLayoutHasNoDataDirArgument() {
        let cmd = QEMUCommand(
            config: VMConfig(cpuCount: 4, memoryMiB: 8192, macAddress: "02:00:00:00:00:01"),
            stack: HostStack(prefix: URL(filePath: "/p", directoryHint: .isDirectory)),
            files: VMFiles(directory: URL(filePath: "/vm", directoryHint: .isDirectory)),
            run: RunPaths(directory: URL(filePath: "/r", directoryHint: .isDirectory)),
            options: LaunchOptions(display: .headless))
        #expect(!cmd.arguments.contains("-L"))
        #expect(cmd.environment["RENDER_SERVER_EXEC_PATH"] == nil)
    }

    @Test func locatePrefersEnclosingBundle() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hoststack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = tmp.appending(path: "Seemless.app")
        let helpers = app.appending(path: "Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let qemu = helpers.appending(path: "qemu-system-aarch64")
        FileManager.default.createFile(atPath: qemu.path(percentEncoded: false), contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        let found = HostStack.locate(environment: [:], executable: app.appending(path: "Contents/MacOS/Seemless"),
                                     currentDirectory: tmp)
        #expect(found?.layout == .appBundle)
        #expect(found?.qemu.resolvingSymlinksInPath() == qemu.resolvingSymlinksInPath())
        let ctl = HostStack.locate(environment: [:], executable: helpers.appending(path: "seemlessctl"), currentDirectory: tmp)
        #expect(ctl?.layout == .appBundle)
        // SEEMLESS_PREFIX still wins.
        #expect(HostStack.locate(environment: ["SEEMLESS_PREFIX": "/x"], executable: qemu)?.layout == .prefix)
    }
}
