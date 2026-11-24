import CSeemlessDisplay
import CoreGraphics
import ImageIO
import Darwin
import Foundation
import IOSurface
import Testing
@testable import SeemlessKit

/// A stand-in for QEMU's `ui/seemless` end, built on the C server half: it
/// checks in a bootstrap name and answers CONNECT the way the patch does.
final class FakeDisplayServer: @unchecked Sendable {
    let name = "app.seemless.test.\(getpid()).\(UUID().uuidString.prefix(8))"
    let port: mach_port_t
    var client: mach_port_t = 0
    var surfaces: [IOSurfaceRef] = []
    let width: Int, height: Int

    init(width: Int = 64, height: Int = 48) throws {
        self.width = width; self.height = height
        var kr: kern_return_t = 0
        port = sld_checkin(name, &kr)
        try #require(port != 0, "bootstrap_check_in failed: \(kr)")
    }

    deinit { mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1) }

    static func makeSurface(width: Int, height: Int, fourcc: UInt32 = SLD_FOURCC_BGRA) -> IOSurfaceRef {
        IOSurfaceCreate([
            kIOSurfaceWidth: width, kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: fourcc,
        ] as CFDictionary)!
    }

    /// Fills a surface with one BGRX colour.
    static func fill(_ s: IOSurfaceRef, b: UInt8, g: UInt8, r: UInt8) {
        IOSurfaceLock(s, [], nil)
        let base = IOSurfaceGetBaseAddress(s).assumingMemoryBound(to: UInt8.self)
        for y in 0..<IOSurfaceGetHeight(s) {
            let row = base + y * IOSurfaceGetBytesPerRow(s)
            for x in 0..<IOSurfaceGetWidth(s) {
                row[x * 4] = b; row[x * 4 + 1] = g; row[x * 4 + 2] = r; row[x * 4 + 3] = 0
            }
        }
        IOSurfaceUnlock(s, [], nil)
    }

    func next(_ timeoutMS: UInt32 = 3000) -> SLDRequest { sld_server_receive(port, timeoutMS) }

    /// Waits for CONNECT and sends a ring of three surfaces (generation 1).
    func accept() throws {
        let r = next()
        try #require(r.id == SLD_C_CONNECT, "expected CONNECT, got \(r.id)")
        #expect(r.sender_uid == getuid())
        client = r.client
        surfaces = (0..<3).map { _ in Self.makeSurface(width: width, height: height) }
        let kr = sld_send_surfaces(client, 0, 1, UInt32(width), UInt32(height), SLD_FOURCC_BGRA,
                                   surfaces[0], surfaces[1], surfaces[2])
        try #require(kr == KERN_SUCCESS)
    }
}

@Suite(.serialized) struct DisplayClientTests {
    @Test func serviceNameIsStablePerRunDirectoryAndShort() {
        let a = RunPaths(directory: URL(filePath: "/tmp/run-1", directoryHint: .isDirectory))
        let b = RunPaths(directory: URL(filePath: "/tmp/run-2", directoryHint: .isDirectory))
        #expect(DisplayExport.serviceName(for: a) == DisplayExport.serviceName(for: a))
        #expect(DisplayExport.serviceName(for: a) != DisplayExport.serviceName(for: b))
        #expect(DisplayExport.serviceName(for: a).hasPrefix("app.seemless.display."))
        #expect(DisplayExport.serviceName(for: a).count < 128, "bootstrap names are name_t (128)")
    }

    @Test func exportedDisplayArguments() {
        let run = RunPaths(directory: URL(filePath: "/r", directoryHint: .isDirectory))
        let cmd = QEMUCommand(
            config: VMConfig(cpuCount: 4, memoryMiB: 8192, macAddress: "02:00:00:00:00:01"),
            stack: HostStack(prefix: URL(filePath: "/p", directoryHint: .isDirectory)),
            files: VMFiles(directory: URL(filePath: "/vm", directoryHint: .isDirectory)),
            run: run, options: LaunchOptions(display: .exported))
        let args = cmd.arguments
        #expect(args.contains("virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2"))
        #expect(args.contains("seemless,gl=es,service=\(DisplayExport.serviceName(for: run))"))
        #expect(!args.contains("cocoa,gl=es"))
    }

    @Test func notExportedIsReported() {
        #expect(throws: DisplayError.notExported("app.seemless.test.nobody")) {
            try DisplayClient(service: "app.seemless.test.nobody")
        }
    }

    @Test func receivesSurfacesAndFramesAndWritesPNG() async throws {
        let server = try FakeDisplayServer()
        let client = try DisplayClient(service: server.name)
        defer { client.close() }
        try server.accept()
        FakeDisplayServer.fill(server.surfaces[2], b: 0, g: 0, r: 255)
        #expect(sld_send_frame(server.client, 0, 1, 2, 7) == KERN_SUCCESS)

        let frame = try await client.nextFrame(timeout: .seconds(3))
        #expect(frame.serial == 7 && frame.index == 2 && frame.width == 64 && frame.height == 48)
        #expect(IOSurfaceGetID(frame.surface) == IOSurfaceGetID(server.surfaces[2]), "same surface, shared memory")
        #expect(DisplayImage.nonBlackFraction(frame.surface) == 1)

        let png = try DisplayImage.png(frame.surface)
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 64 && image.height == 48)
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        #expect(px[0] > 250 && px[1] < 5 && px[2] < 5, "red survives the BGRA → PNG path")

        // A later frame wakes a waiter that asked for something newer.
        async let later = client.nextFrame(after: 7, timeout: .seconds(3))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sld_send_frame(server.client, 0, 1, 0, 8) == KERN_SUCCESS)
        let next = try await later
        #expect(next.serial == 8)
    }

    @Test func ackAndSizeRequestsReachTheServer() async throws {
        let server = try FakeDisplayServer()
        let client = try DisplayClient(service: server.name)
        defer { client.close() }
        try server.accept()
        #expect(sld_send_frame(server.client, 0, 1, 1, 1) == KERN_SUCCESS)
        let frame = try await client.nextFrame(timeout: .seconds(3))
        client.acknowledge(frame)
        let ack = server.next()
        #expect(ack.id == SLD_C_ACK && ack.index == 1 && ack.generation == 1)
        try client.requestSize(width: 1920, height: 1080)
        let size = server.next()
        #expect(size.id == SLD_C_SET_SIZE && size.width == 1920 && size.height == 1080)
    }

    @Test func cursorAndPointer() async throws {
        let server = try FakeDisplayServer()
        let client = try DisplayClient(service: server.name)
        defer { client.close() }
        try server.accept()
        var pixels = [UInt32](repeating: 0xFF00_FF00, count: 32 * 32)
        #expect(sld_send_cursor(server.client, 0, 3, 32, 32, 4, 5, &pixels) == KERN_SUCCESS)
        #expect(sld_send_mouse(server.client, 0, 100, 200, true) == KERN_SUCCESS)
        #expect(sld_send_frame(server.client, 0, 1, 0, 1) == KERN_SUCCESS)  // messages are ordered
        _ = try await client.nextFrame(timeout: .seconds(3))
        let c = try #require(client.cursor())
        #expect(c.width == 32 && c.hotX == 4 && c.hotY == 5 && c.serial == 3 && c.pixels.count == 32 * 32 * 4)
        #expect(client.pointer() == DisplayPointer(x: 100, y: 200, visible: true))
    }

    /// The other end runs guest-influenced code: malformed messages and
    /// surfaces that do not match their header are dropped, not trusted.
    @Test func malformedMessagesAreRejected() async throws {
        let server = try FakeDisplayServer()
        let client = try DisplayClient(service: server.name)
        defer { client.close() }
        try server.accept()

        #expect(sld_send_raw(server.client, 0x1234_5678, 64) == KERN_SUCCESS)        // unknown id
        #expect(sld_send_raw(server.client, UInt32(SLD_Q_FRAME), 32) == KERN_SUCCESS)        // truncated frame
        #expect(sld_send_frame(server.client, 0, 1, 9, 1) == KERN_SUCCESS)           // slot out of range
        #expect(sld_send_frame(server.client, 0, 99, 0, 1) == KERN_SUCCESS)          // stale generation
        // Header claims 64x48 but the surfaces are 32x32.
        let wrong = (0..<3).map { _ in FakeDisplayServer.makeSurface(width: 32, height: 32) }
        _ = sld_send_surfaces(server.client, 0, 2, 64, 48, SLD_FOURCC_BGRA, wrong[0], wrong[1], wrong[2])
        #expect(sld_send_frame(server.client, 0, 1, 0, 5) == KERN_SUCCESS)          // still valid afterwards

        let frame = try await client.nextFrame(timeout: .seconds(3))
        #expect(frame.serial == 5 && frame.generation == 1)
        // Unknown id, truncated frame, slot 9 and mismatched surfaces fail validation;
        // the stale-generation frame is valid on the wire and ignored by the client.
        #expect(client.rejectedMessages == 4)
        #expect(client.scanout()?.generation == 1, "bad surface set did not replace the good one")
    }

    @Test func closeFailsPendingWait() async throws {
        let server = try FakeDisplayServer()
        let client = try DisplayClient(service: server.name)
        try server.accept()
        let wait = Task { try await client.nextFrame(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        client.close()
        await #expect(throws: DisplayError.closed) { _ = try await wait.value }
    }
}

/// Boots the real patched QEMU to firmware with `-display seemless` and reads
/// the exported scanout. Skipped when the stack is missing or lacks the patch.
@Suite(.serialized, .enabled(if: seemlessDisplayAvailable, "QEMU without -display seemless (patches/qemu/0001)"))
struct DisplayExportIntegrationTests {
    @Test func firmwareScanoutIsExported() async throws {
        let root = try temporaryDirectory()
        let run = URL(filePath: "/tmp/sl-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: run) }
        let store = VMStore(layout: StorageLayout(root: root), stack: builtStack!)
        let config = VMConfig(cpuCount: 2, memoryMiB: 4096, diskSizeGiB: 32, network: .none,
                              macAddress: "02:00:00:00:00:05")
        let files = try await store.create(config)
        let vm = VMProcess(config: config, stack: builtStack!, files: files,
                           options: LaunchOptions(display: .exported), runDirectory: run)
        try await vm.start()
        defer { Task { await vm.stop(graceful: .zero) } }

        // QEMU checks in during init; retry briefly in case we are early.
        var client: DisplayClient?
        for _ in 0..<50 where client == nil {
            client = try? DisplayClient(run: RunPaths(directory: run))
            if client == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let c = try #require(client)
        defer { c.close() }
        // Firmware draws within a few seconds; wait for a frame with content.
        var frame = try await c.nextFrame(timeout: .seconds(10))
        let deadline = Date().addingTimeInterval(20)
        while DisplayImage.nonBlackFraction(frame.surface) < 0.001 && Date() < deadline {
            frame = try await c.nextFrame(after: frame.serial, timeout: .seconds(5))
        }
        #expect(frame.source == 1, "firmware is a 2D surface")
        #expect(frame.width >= 640 && frame.height >= 480)
        #expect(DisplayImage.nonBlackFraction(frame.surface) > 0.001, "firmware drew something")

        // A second client (e.g. `seemlessctl screenshot` next to the app) works too.
        let second = try DisplayClient(run: RunPaths(directory: run))
        defer { second.close() }
        let f2 = try await second.nextFrame(timeout: .seconds(5))
        #expect(f2.width == frame.width)
        await vm.stop(graceful: .zero)
    }
}

let seemlessDisplayAvailable: Bool = {
    guard stackAvailable, let stack = builtStack else { return false }
    let p = Process()
    p.executableURL = stack.qemu
    p.arguments = ["-display", "help"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return text.split(separator: "\n").contains("seemless")
}()

@Suite struct VMScreenshotTests {
    @Test func fileNameLooksLikeAMacScreenshot() {
        let date = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18 11.06.40 UTC
        #expect(VMScreenshot.fileName(vm: "Windows 11", date: date, timeZone: TimeZone(identifier: "UTC")!)
                == "Seemless Windows 11 2026-11-18 at 11.06.40.png")
        #expect(!VMScreenshot.fileName(vm: "a/b:c").contains("/"))
    }

    @Test func defaultDirectoryFollowsScreencaptureLocation() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "app.seemless.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = URL(filePath: "/Users/x", directoryHint: .isDirectory)
        #expect(VMScreenshot.defaultDirectory(defaults: defaults, home: home).path() == "/Users/x/Desktop/")
        defaults.set(dir.path(percentEncoded: false), forKey: "location")
        #expect(VMScreenshot.defaultDirectory(defaults: defaults, home: home).standardizedFileURL
                == dir.standardizedFileURL)
        defaults.set("/does/not/exist", forKey: "location")
        #expect(VMScreenshot.defaultDirectory(defaults: defaults, home: home).path() == "/Users/x/Desktop/")
    }

    @Test func onlyABlackScreendumpIsFlagged() {
        func shot(_ s: VMScreenshot.Source, _ f: Double) -> VMScreenshot {
            VMScreenshot(png: Data(), width: 1, height: 1, source: s, nonBlackFraction: f)
        }
        #expect(shot(.qmpScreendump, 0).isLikelyBlankScreendump)
        #expect(!shot(.qmpScreendump, 0.3).isLikelyBlankScreendump)
        #expect(!shot(.exportedMetal, 0).isLikelyBlankScreendump)
    }
}

/// `VMManager.screenshot` against real QEMU in both display modes.
@Suite(.serialized, .enabled(if: seemlessDisplayAvailable, "QEMU without -display seemless (patches/qemu/0001)"))
struct VMScreenshotIntegrationTests {
    func screenshot(display: LaunchOptions.Display) async throws -> VMScreenshot {
        let root = URL(filePath: "/tmp/sl-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = VMManager(layout: StorageLayout(root: root), stack: builtStack!)
        let config = VMConfig(name: "shot", cpuCount: 2, memoryMiB: 4096, diskSizeGiB: 32, network: .none,
                              macAddress: "02:00:00:00:00:06")
        _ = try await manager.create(config)
        try await manager.start("shot", options: LaunchOptions(display: display))
        defer { Task { _ = try? await manager.stop("shot", graceful: .zero) } }
        // Wait until firmware has drawn something.
        var shot = try await manager.screenshot("shot")
        let deadline = Date().addingTimeInterval(20)
        while shot.nonBlackFraction < 0.001 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            shot = try await manager.screenshot("shot")
        }
        _ = try await manager.stop("shot", graceful: .zero)
        return shot
    }

    @Test func exportedDisplayUsesTheIOSurface() async throws {
        let shot = try await screenshot(display: .exported)
        #expect(shot.source == .exported2D)
        #expect(shot.nonBlackFraction > 0.001)
        #expect(CGImageSourceCreateWithData(shot.png as CFData, nil) != nil)
    }

    @Test func otherDisplaysFallBackToScreendump() async throws {
        let shot = try await screenshot(display: .headless)
        #expect(shot.source == .qmpScreendump)
        #expect(shot.nonBlackFraction > 0.001 && !shot.isLikelyBlankScreendump)
    }
}
