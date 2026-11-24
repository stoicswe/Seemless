import Darwin
import Foundation
import Testing
@testable import SeemlessKit

@Suite struct GuestLaunchNameTests {
    @Test func guestFileNamesAreSafeForWindows() {
        #expect(GuestLaunch.guestFileName(for: URL(filePath: "/d/Firefox Setup 140.0.exe")) == "Firefox Setup 140.0.exe")
        #expect(GuestLaunch.guestFileName(for: URL(filePath: "/d/a:b*c?.EXE")) == "a_b_c_.exe")
        #expect(GuestLaunch.guestFileName(for: URL(filePath: "/d/ .msi")) == "installer.msi")
        #expect(GuestLaunch.guestFileName(for: URL(filePath: "/d/" + String(repeating: "x", count: 300) + ".exe")).count == 124)
    }

    @Test func onlyInstallersAreSupported() async throws {
        #expect(GuestLaunch.isSupported(URL(filePath: "/a/b.exe")))
        #expect(GuestLaunch.isSupported(URL(filePath: "/a/b.MSI")))
        #expect(!GuestLaunch.isSupported(URL(filePath: "/a/b.dmg")))
        await #expect(throws: GuestLaunch.LaunchError.unsupportedType("x.zip")) {
            _ = try await GuestLaunch.makeDrive(for: URL(filePath: "/tmp/x.zip"), in: URL(filePath: "/tmp"))
        }
        await #expect(throws: GuestLaunch.LaunchError.self) {
            _ = try await GuestLaunch.makeDrive(for: URL(filePath: "/tmp/does-not-exist-\(UUID()).exe"), in: URL(filePath: "/tmp"))
        }
    }

    @Test func driveHoldsInstallerRequestAndLauncherScripts() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installer = dir.appending(path: "Firefox Setup.exe")
        try Data("MZ fake installer".utf8).write(to: installer)
        let request = try await GuestLaunch.makeDrive(for: installer, in: dir.appending(path: "launch"), assets: repoAssets)
        #expect(request.id.wholeMatch(of: /[0-9a-f]{32}/) != nil)
        #expect(request.fileName == "Firefox Setup.exe")
        #expect(request.nodeName.count <= 31, "QEMU node names are limited")

        try await FATImage.withMounted(request.image, readOnly: true) { root in
            // The guest launcher finds the drive by this label.
            #expect(try root.resourceValues(forKeys: [.volumeNameKey]).volumeName == GuestLaunch.volumeLabel)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            #expect(Set(names).isSuperset(of: ["Firefox Setup.exe", "seemless-launch.txt", "README.txt",
                                               "SeemlessLauncher.ps1", "register-launcher.ps1", "Enable automatic installs.cmd"]))
            #expect(!names.contains { $0.hasPrefix("._") }, "no AppleDouble files on the drive")
            let req = try String(contentsOf: root.appending(path: "seemless-launch.txt"), encoding: .utf8)
            #expect(req == "\(request.id)\r\nFirefox Setup.exe\r\n")
            #expect(try Data(contentsOf: root.appending(path: "Firefox Setup.exe")) == Data("MZ fake installer".utf8))
        }
    }
}

/// Hot-plugging into real QEMU (firmware only; no Windows needed).
@Suite(.serialized, .enabled(if: stackAvailable, "host stack not built (scripts/build-deps.sh all)"))
struct GuestLaunchIntegrationTests {
    @Test func hotPlugsAndReplacesLaunchDrives() async throws {
        let root = URL(filePath: "/tmp/slg-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let m = VMManager(layout: StorageLayout(root: root), stack: builtStack!)
        defer {
            if let r = RunningVM.read(m.store.files(for: "vm")), r.isAlive {
                kill(r.qemuPID, SIGKILL)
                if r.swtpmPID > 0 { kill(r.swtpmPID, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try await m.create(VMConfig(name: "vm", cpuCount: 2, memoryMiB: 4096, diskSizeGiB: 32, network: .none,
                                    macAddress: "02:00:00:00:00:05"))
        let installer = root.appending(path: "setup.exe")
        try Data("MZ".utf8).write(to: installer)

        await #expect(throws: GuestLaunch.LaunchError.notRunning("vm")) { try await m.launch("vm", installer: installer) }

        try await m.start("vm", options: LaunchOptions(display: .headless))
        let first = try await m.launch("vm", installer: installer)
        let qmp = try await VMRemote.attach(m.store.files(for: "vm"))!.connect()
        defer { Task { await qmp.close() } }
        #expect(try await GuestLaunch.attachedNodes(qmp: qmp) == [first.nodeName])
        let peripherals = try await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"])
        #expect((peripherals.arrayValue ?? []).contains { $0["name"]?.stringValue == first.deviceID })

        // A younger drive is kept; with replaceAfter zero the old one goes.
        let second = try await m.launch("vm", installer: installer)
        #expect(Set(try await GuestLaunch.attachedNodes(qmp: qmp)) == [first.nodeName, second.nodeName])
        let third = try await m.launch("vm", installer: installer, replaceAfter: .zero)
        #expect(try await GuestLaunch.attachedNodes(qmp: qmp) == [third.nodeName])
        #expect(!FileManager.default.fileExists(atPath: first.image.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: third.image.path(percentEncoded: false)))

        try await m.stop("vm", graceful: .zero)
        // The next start clears the previous run's drives.
        try await m.start("vm", options: LaunchOptions(display: .headless), resume: false)
        #expect(!FileManager.default.fileExists(atPath: m.launchDirectory("vm").path(percentEncoded: false)))
        try await m.stop("vm", graceful: .zero)
    }
}
