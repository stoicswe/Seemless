import Darwin
import Foundation
import Testing
@testable import SeemlessKit

/// Boots the real host stack to UEFI firmware (no Windows needed).
/// Skipped when the stack is not built. Serialized: each test owns a VM.
@Suite(.serialized, .enabled(if: stackAvailable, "host stack not built (scripts/build-deps.sh all)"))
struct VMProcessIntegrationTests {
    struct Fixture {
        let root: URL
        let store: VMStore
        let files: VMFiles
        let config: VMConfig
        let run: URL

        func process(_ options: LaunchOptions = LaunchOptions(display: .headless)) -> VMProcess {
            VMProcess(config: config, stack: builtStack!, files: files, options: options, runDirectory: run)
        }

        /// Also kills a VM a failed test left running, so failures do not
        /// leave orphaned QEMU/swtpm processes behind.
        func remove() {
            if let record = RunningVM.read(files), record.isAlive {
                kill(record.qemuPID, SIGKILL)
                if record.swtpmPID > 0 { kill(record.swtpmPID, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: run)
        }
    }

    func fixture() async throws -> Fixture {
        let root = try temporaryDirectory()
        let store = VMStore(layout: StorageLayout(root: root), stack: builtStack!)
        let config = VMConfig(cpuCount: 2, memoryMiB: 4096, diskSizeGiB: 32, network: .none,
                              macAddress: "02:00:00:00:00:03")
        let files = try await store.create(config)
        // Socket paths must stay short (sun_path), so not under $TMPDIR.
        let run = URL(filePath: "/tmp/sl-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        return Fixture(root: root, store: store, files: files, config: config, run: run)
    }

    @Test func bootPauseResumeStop() async throws {
        let f = try await fixture(); defer { f.remove() }
        let vm = f.process()
        try await vm.start()
        #expect(await vm.state == .running)

        let qmp = try #require(await vm.qmp)
        #expect(try await qmp.queryStatus() == .init(running: true, state: "running"))
        let tpm = try await qmp.execute("query-tpm")
        #expect(tpm.arrayValue?.first?["model"]?.stringValue == "tpm-tis")

        // The running record lets another process find the VM.
        let remote = try #require(VMRemote.attach(f.files))
        #expect(remote.record.qemuPID == (await vm.qemuPID))
        let other = try await remote.connect()
        #expect(try await other.queryStatus().running)
        await other.close()

        try await vm.pause()
        #expect(await vm.state == .paused)
        #expect(try await qmp.queryStatus().state == "paused")
        try await vm.resume()
        #expect(await vm.state == .running)

        // Firmware has no OS to honour the ACPI power button, so a short
        // graceful window falls through to QMP quit.
        let how = await vm.stop(graceful: .seconds(2))
        #expect(how == .quit || how == .guestShutdown)
        #expect(await vm.state == .stopped)
        #expect(VMRemote.attach(f.files) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.files.runningRecord.path(percentEncoded: false)))
        let logs = try FileManager.default.contentsOfDirectory(atPath: f.files.logs.path(percentEncoded: false))
        #expect(logs.contains { $0.hasPrefix("qemu-") }, "QEMU log archived")
    }

    @Test func secondStartWhileRunningIsRefused() async throws {
        let f = try await fixture(); defer { f.remove() }
        let first = f.process()
        try await first.start()
        let second = VMProcess(config: f.config, stack: builtStack!, files: f.files,
                               options: LaunchOptions(display: .headless),
                               runDirectory: URL(filePath: "/tmp/sl-\(UUID().uuidString.prefix(6))"))
        await #expect(throws: VMProcess.ProcessError.self) { try await second.start() }
        await first.stop(graceful: .zero)
        #expect(await first.state == .stopped)
    }

    @Test func remoteStopFromAnotherController() async throws {
        let f = try await fixture(); defer { f.remove() }
        let vm = f.process()
        try await vm.start()
        let remote = try #require(VMRemote.attach(f.files))
        let how = try await remote.stop(graceful: .zero)
        #expect(how == .quit)
        #expect(await vm.waitForExit(timeout: .seconds(5)))
        #expect(await vm.state == .stopped, "a stop by QMP quit is not a crash")
    }

    @Test func killedQEMUIsReportedAsCrash() async throws {
        let f = try await fixture(); defer { f.remove() }
        let vm = f.process()
        try await vm.start()
        let pid = try #require(await vm.qemuPID)
        kill(pid, SIGKILL)
        #expect(await vm.waitForExit(timeout: .seconds(5)))
        guard case .crashed(let why) = await vm.state else {
            Issue.record("expected crashed, got \(await vm.state)"); return
        }
        #expect(why.contains("signal 9"))
        #expect(VMRemote.attach(f.files) == nil, "running record removed after a crash")
    }

    @Test func startPausedStaysInPrelaunch() async throws {
        let f = try await fixture(); defer { f.remove() }
        let vm = f.process()
        try await vm.start(resume: false)
        #expect(await vm.state == .paused)
        #expect(try await vm.qmp!.queryStatus().state == "prelaunch")
        try await vm.resume()
        #expect(try await vm.qmp!.queryStatus().running)
        await vm.stop(graceful: .zero)
    }
}
