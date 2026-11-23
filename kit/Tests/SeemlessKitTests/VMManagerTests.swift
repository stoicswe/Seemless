import Darwin
import Foundation
import Testing
@testable import SeemlessKit

@Suite struct BootSettingsTests {
    func command(_ cfg: VMConfig, drives: [RemovableDrive] = []) -> [String] {
        QEMUCommand(
            config: cfg,
            stack: HostStack(prefix: URL(filePath: "/p", directoryHint: .isDirectory)),
            files: VMFiles(directory: URL(filePath: "/vm", directoryHint: .isDirectory)),
            run: RunPaths(directory: URL(filePath: "/r", directoryHint: .isDirectory)),
            options: LaunchOptions(removableDrives: drives)
        ).arguments
    }

    func base() -> VMConfig { VMConfig(cpuCount: 2, memoryMiB: 4096, macAddress: "02:00:00:00:00:01") }

    @Test func configWrittenBeforeBootSettingsStillLoads() throws {
        let old = """
        {"name":"old","cpuCount":4,"memoryMiB":8192,"diskSizeGiB":64,"graphicsBackend":"dxmt",
         "network":"user","portForwards":[],"macAddress":"02:00:00:00:00:09"}
        """
        let c = try JSONDecoder().decode(VMConfig.self, from: Data(old.utf8))
        #expect(c.boot == VMConfig.BootSettings())
        #expect(c.boot.tpm && c.boot.order == .diskFirst && c.boot.firmwareTimeoutSeconds == 0)
        #expect(c.media.isEmpty)
    }

    @Test func roundTripsBootAndMedia() throws {
        var c = base()
        c.boot = .init(order: .removableFirst, tpm: false, firmwareTimeoutSeconds: 3)
        c.media = [.init(path: "/a/win.iso"), .init(path: "/a/drivers.img", kind: .disk)]
        let back = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func persistedMediaComeBeforeLaunchDrivesAndDiskBootsFirst() {
        var c = base()
        c.media = [.init(path: "/a/win.iso")]
        let args = command(c, drives: [RemovableDrive(id: "x", file: URL(filePath: "/a/x.img"), isCDROM: false)])
        #expect(args.contains("nvme,drive=sys,serial=seemless0,bootindex=1"))
        #expect(args.contains("if=none,id=m0,file=/a/win.iso,format=raw,media=cdrom,readonly=on"))
        #expect(args.contains("usb-storage,bus=usb.0,drive=m0,removable=on,bootindex=2"))
        #expect(args.contains("usb-storage,bus=usb.0,drive=x,removable=on,bootindex=3"))
        #expect(!args.contains("-boot"), "no firmware wait by default")
    }

    @Test func removableFirstPutsDiskLast() {
        var c = base()
        c.boot.order = .removableFirst
        c.media = [.init(path: "/a/win.iso"), .init(path: "/a/tools.iso")]
        let args = command(c)
        #expect(args.contains("usb-storage,bus=usb.0,drive=m0,removable=on,bootindex=1"))
        #expect(args.contains("usb-storage,bus=usb.0,drive=m1,removable=on,bootindex=2"))
        #expect(args.contains("nvme,drive=sys,serial=seemless0,bootindex=3"))
    }

    @Test func tpmOffRemovesTPMDevices() {
        var c = base()
        c.boot.tpm = false
        let joined = command(c).joined(separator: " ")
        #expect(!joined.contains("tpm"))
    }

    @Test func firmwareTimeoutEnablesBootMenu() {
        var c = base()
        c.boot.firmwareTimeoutSeconds = 5
        let args = command(c)
        let i = try? #require(args.firstIndex(of: "-boot"))
        #expect(i.map { args[$0 + 1] } == "menu=on,splash-time=5000")
    }

    @Test func validation() {
        let host = HostInfo(performanceCores: 4, logicalCores: 8, memoryMiB: 24_576)
        var c = base()
        c.boot.firmwareTimeoutSeconds = 31
        c.media = [.init(path: "relative.iso"), .init(path: "relative.iso")]
        c.portForwards = [.init(hostPort: 0, guestPort: 1)]
        c.name = "a,b"
        let errors = c.validationErrors(host: host)
        #expect(errors.count == 5, "\(errors)")
        #expect(VMConfig(name: "Windows 11", cpuCount: 2, memoryMiB: 4096, macAddress: "02:00:00:00:00:01")
            .validationErrors(host: host).isEmpty, "spaces are fine in names")
    }

    @Test func bootKeys() {
        #expect(BootKeys.cdPrompt.qcode == "spc")
        #expect(BootKeys.firmwareSetup.qcode == "esc")
        #expect(BootKeys.firmwareSetup.duration < BootKeys.cdPrompt.duration)
    }
}

/// VMManager against the real host stack (qemu-img; QEMU for lifecycle).
@Suite(.serialized, .enabled(if: stackAvailable, "host stack not built (scripts/build-deps.sh all)"))
struct VMManagerTests {
    /// Socket paths must stay short (sun_path), so the root is under /tmp.
    func manager() throws -> (VMManager, URL) {
        let root = URL(filePath: "/tmp/slm-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (VMManager(layout: StorageLayout(root: root), stack: builtStack!), root)
    }

    func config(_ name: String, tpm: Bool = true) -> VMConfig {
        VMConfig(name: name, cpuCount: 2, memoryMiB: 4096, diskSizeGiB: 32, network: .none,
                 macAddress: "02:00:00:00:00:04", boot: .init(tpm: tpm))
    }

    func cleanUp(_ m: VMManager, _ root: URL) async {
        for c in await m.list().configs {
            if let r = RunningVM.read(m.store.files(for: c.name)), r.isAlive {
                kill(r.qemuPID, SIGKILL)
                if r.swtpmPID > 0 { kill(r.swtpmPID, SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func listUpdateMediaAndResets() async throws {
        let (m, root) = try manager()
        defer { Task { await cleanUp(m, root) } }
        try await m.create(config("b"))
        try await m.create(config("a"))
        // A directory with a corrupt config is reported, not hidden.
        let broken = m.store.files(for: "zz")
        try FileManager.default.createDirectory(at: broken.directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.config)
        let listed = await m.list()
        #expect(listed.configs.map(\.name) == ["a", "b"])
        #expect(listed.broken == ["zz"])
        #expect(await m.status(of: "a") == .stopped)

        // Grow the disk; shrinking is refused.
        var c = try m.store.load("a")
        c.diskSizeGiB = 40
        c.boot.order = .removableFirst
        try await m.update(c)
        #expect(try await m.diskInfo("a").virtualSize == 40 << 30)
        #expect(try m.store.load("a").boot.order == .removableFirst)
        c.diskSizeGiB = 33
        await #expect(throws: VMManager.ManagerError.cannotShrinkDisk(40, 33)) { try await m.update(c) }

        // Media: attach is idempotent; .iso means CD-ROM.
        let iso = root.appending(path: "x.iso")
        try Data(count: 2048).write(to: iso)
        _ = try await m.attachMedia("a", file: iso)
        let attached = try await m.attachMedia("a", file: iso)
        #expect(attached.media == [.init(path: iso.path(percentEncoded: false), kind: .cdrom)])
        #expect(try await m.detachMedia("a", path: iso.path(percentEncoded: false)).media.isEmpty)
        await #expect(throws: VMManager.ManagerError.self) {
            _ = try await m.attachMedia("a", file: root.appending(path: "missing.iso"))
        }

        // Firmware vars come back blank and the right size; TPM dir is emptied.
        let files = m.store.files(for: "a")
        try Data("junk".utf8).write(to: files.efiVars)
        try Data("sealed".utf8).write(to: files.tpmState.appending(path: "tpm2-00.permall"))
        try await m.resetFirmwareVariables("a")
        try await m.resetTPM("a")
        let size = try FileManager.default.attributesOfItem(atPath: files.efiVars.path(percentEncoded: false))[.size] as? UInt64
        #expect(size == DiskTool.efiVarsSize)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.tpmState.path(percentEncoded: false)).isEmpty)

        try await m.createSnapshot("a", label: "clean")
        try await m.revertSnapshot("a", label: "clean")
        try await m.deleteSnapshot("a", label: "clean")

        try await m.delete("b")
        #expect(await m.list().configs.map(\.name) == ["a"])
    }

    @Test func lifecycleWithoutTPMAndSettingsLockedWhileRunning() async throws {
        let (m, root) = try manager()
        defer { Task { await cleanUp(m, root) } }
        try await m.create(config("vm", tpm: false))
        try await m.start("vm", options: LaunchOptions(display: .headless))
        var s = await m.status(of: "vm")
        #expect(s.state == .running && s.owner == .here && s.qemuPID != nil)
        #expect(RunningVM.read(m.store.files(for: "vm"))?.swtpmPID == 0, "no swtpm without a TPM")

        await #expect(throws: VMManager.ManagerError.running("vm")) { try await m.start("vm") }
        await #expect(throws: VMManager.ManagerError.running("vm")) { try await m.update(config("vm")) }
        await #expect(throws: VMManager.ManagerError.running("vm")) { try await m.delete("vm") }

        try await m.pause("vm")
        #expect(await m.status(of: "vm").state == .paused)
        try await m.reset("vm")
        #expect(await m.status(of: "vm").state == .running, "reset of a paused VM resumes it")
        #expect(await m.ownedActiveNames == ["vm"])

        // A second manager (another process, e.g. the CLI) sees it as running elsewhere.
        let other = VMManager(layout: m.layout, stack: m.stack)
        s = await other.status(of: "vm")
        #expect(s.state == .running && s.owner == .elsewhere)
        try await other.pause("vm")
        #expect(await other.status(of: "vm").state == .paused)
        try await other.resume("vm")

        let how = try await m.stop("vm", graceful: .seconds(1))
        #expect(how == .quit || how == .guestShutdown)
        #expect(await m.status(of: "vm") == .stopped)
        #expect(await m.ownedActiveNames.isEmpty)
    }

    @Test func stopFromAnotherManager() async throws {
        let (m, root) = try manager()
        defer { Task { await cleanUp(m, root) } }
        try await m.create(config("vm"))
        try await m.start("vm", options: LaunchOptions(display: .headless), resume: false)
        #expect(await m.status(of: "vm").state == .paused)
        let other = VMManager(layout: m.layout, stack: m.stack)
        #expect(try await other.stop("vm", graceful: .zero) == .quit)
        // The owner notices the exit as a normal stop, not a crash.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await m.status(of: "vm") == .stopped)
    }
}
