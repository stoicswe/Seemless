import Foundation
import Testing
@testable import SeemlessKit

/// Real qemu-img from build/prefix. Skipped when the host stack is not built.
let builtStack = HostStack.locate()
let stackAvailable = builtStack.map { $0.missingFiles().isEmpty } ?? false

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "seemless-test-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.enabled(if: stackAvailable, "host stack not built (scripts/build-deps.sh all)"))
struct DiskToolTests {
    let disks = DiskTool(stack: builtStack!)

    @Test func createInfoResize() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let disk = dir.appending(path: "a.qcow2")
        try await disks.createDisk(at: disk, sizeGiB: 2)
        var info = try await disks.info(disk)
        #expect(info.format == "qcow2")
        #expect(info.virtualSize == 2 << 30)
        #expect(info.actualSize < 10 << 20, "sparse: a new image should be tiny")
        #expect(info.backingFile == nil)

        try await disks.resize(disk, toGiB: 3)
        info = try await disks.info(disk)
        #expect(info.virtualSize == 3 << 30)
        await #expect(throws: DiskTool.DiskError.self) { try await disks.resize(disk, toGiB: 1) }
        await #expect(throws: DiskTool.DiskError.exists(disk.path(percentEncoded: false))) {
            try await disks.createDisk(at: disk, sizeGiB: 1)
        }
    }

    @Test func overlayAndReset() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appending(path: "base.qcow2"), overlay = dir.appending(path: "system.qcow2")
        try await disks.createDisk(at: base, sizeGiB: 1)
        try await disks.createOverlay(at: overlay, base: base)
        #expect(try await disks.info(overlay).backingFile == base.path(percentEncoded: false))

        // Write into the overlay, then reset and check the write is gone.
        try await ProcessRunner.run(builtStack!.qemuImg.deletingLastPathComponent().appending(path: "qemu-io"),
                                    ["-f", "qcow2", "-c", "write -P 0xab 0 1M", overlay.path(percentEncoded: false)])
        let grown = try await disks.info(overlay).actualSize
        try await disks.resetOverlay(overlay)
        let info = try await disks.info(overlay)
        #expect(info.backingFile == base.path(percentEncoded: false))
        #expect(info.actualSize < grown)

        await #expect(throws: DiskTool.DiskError.notAnOverlay(base.path(percentEncoded: false))) {
            try await disks.resetOverlay(base)
        }
    }

    @Test func offlineSnapshots() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let disk = dir.appending(path: "s.qcow2")
        try await disks.createDisk(at: disk, sizeGiB: 1)
        try await disks.createSnapshot(disk, name: "clean-install")
        #expect(try await disks.info(disk).snapshots.map(\.name) == ["clean-install"])
        try await disks.applySnapshot(disk, name: "clean-install")
        try await disks.deleteSnapshot(disk, name: "clean-install")
        #expect(try await disks.info(disk).snapshots.isEmpty)
        await #expect(throws: DiskTool.DiskError.invalidSnapshotName("a b;rm")) {
            try await disks.createSnapshot(disk, name: "a b;rm")
        }
    }

    @Test func efiVarsAre64MiB() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let vars = dir.appending(path: "efi_vars.fd")
        try DiskTool.createEFIVars(at: vars)
        let size = try FileManager.default.attributesOfItem(atPath: vars.path(percentEncoded: false))[.size] as? UInt64
        #expect(size == 64 << 20)
        #expect(throws: DiskTool.DiskError.self) { try DiskTool.createEFIVars(at: vars) }
    }

    @Test func storeCreatesLoadsAndDeletes() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = VMStore(layout: StorageLayout(root: dir), stack: builtStack!)
        let cfg = VMConfig(cpuCount: 2, memoryMiB: 4096, diskSizeGiB: 32, macAddress: "02:00:00:00:00:02")
        let files = try await store.create(cfg)
        for f in [files.config, files.systemDisk, files.efiVars, files.tpmState, files.logs] {
            #expect(FileManager.default.fileExists(atPath: f.path(percentEncoded: false)), "\(f.lastPathComponent)")
        }
        #expect(try store.load("default") == cfg)
        await #expect(throws: VMStore.StoreError.alreadyExists("default")) { try await store.create(cfg) }
        try store.delete("default")
        #expect(!store.exists("default"))
    }

    @Test func storeRejectsInvalidConfigWithoutLeavingFiles() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = VMStore(layout: StorageLayout(root: dir), stack: builtStack!)
        let bad = VMConfig(cpuCount: 2, memoryMiB: 1024, macAddress: "02:00:00:00:00:02")
        await #expect(throws: VMStore.StoreError.self) { try await store.create(bad) }
        #expect(!FileManager.default.fileExists(atPath: store.files(for: "default").directory.path(percentEncoded: false)))
    }
}

@Suite struct ProcessRunnerTests {
    /// More output than a pipe buffer holds must not deadlock.
    @Test func largeOutputDoesNotDeadlock() async throws {
        let out = try await ProcessRunner.run(URL(filePath: "/bin/sh"),
                                              ["-c", "head -c 1000000 /dev/zero; head -c 200000 /dev/zero >&2"])
        #expect(out.stdout.count == 1_000_000)
        #expect(out.stderr.utf8.count == 200_000)
    }

    @Test func nonZeroExitThrowsWithStderr() async throws {
        do {
            try await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "echo boom >&2; exit 3"])
            Issue.record("expected failure")
        } catch let f as ProcessRunner.Failure {
            #expect(f.output.status == 3)
            #expect(f.description.hasSuffix("boom"))
        }
    }
}
