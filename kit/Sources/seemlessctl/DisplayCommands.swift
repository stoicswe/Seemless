import ArgumentParser
import Foundation
import SeemlessKit

/// `seemlessctl screenshot`: the agents' eyes (docs/04 "Debugging aids").
struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Save a running VM's scanout as PNG, from the exported IOSurface.",
        discussion: """
        Works with the 3D driver loaded (QMP screendump returns black then). Needs a VM started with \
        `vm run --export-display`; for a VM in QEMU's own window it falls back to QMP screendump and says so.
        """
    )
    @OptionGroup var vm: VMSelection
    @Option(help: "Scanout (0 = desktop, 1 = atlas).") var scanout: UInt32 = 0
    @Option(help: "Output PNG.") var out: String
    @Option(help: "Seconds to wait for a frame.") var timeout: Double = 10
    @Flag(help: "Fail instead of falling back to QMP screendump.") var noFallback = false

    func run() async throws {
        _ = try vm.remote()   // clear "not running" error
        let url = URL(filePath: out).standardizedFileURL
        let manager = VMManager(layout: vm.layout, stack: try vm.stack())
        if noFallback {
            _ = try DisplayClient(run: try vm.remote().record.run).close()
        }
        let shot = try await manager.screenshot(vm.name, scanout: scanout, timeout: .seconds(timeout))
        try shot.png.write(to: url)
        FileHandle.standardError.write(Data(String(format: "%dx%d scanout %u, %@, %.0f%% non-black\n",
                                                  shot.width, shot.height, scanout, shot.source.rawValue,
                                                  shot.nonBlackFraction * 100).utf8))
        if shot.isLikelyBlankScreendump {
            FileHandle.standardError.write(Data("note: QMP screendump is black once the 3D driver owns the display; start the VM with `vm run --export-display`\n".utf8))
        }
        print(url.path(percentEncoded: false))
    }
}

struct DisplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "Inspect or resize a running VM's exported display.",
        subcommands: [Info.self, Size.self]
    )

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print scanouts, frame source, cursor and pointer.")
        @OptionGroup var vm: VMSelection
        func run() async throws {
            let remote = try vm.remote()
            let client = try DisplayClient(run: remote.record.run)
            defer { client.close() }
            print("service \(client.service)")
            _ = try? await client.nextFrame(head: 0, timeout: .seconds(3))
            for head in UInt32(0)..<4 {
                guard let s = client.scanout(head: head) else { continue }
                let f = client.latestFrame(head: head)
                let src = f.map { $0.source == 2 ? "metal" : "2d" } ?? "no frame yet"
                print("scanout \(head): \(s.width)x\(s.height) generation \(s.generation), \(src)")
                if let c = client.cursor(head: head) {
                    print("  cursor \(c.width)x\(c.height) hotspot \(c.hotX),\(c.hotY) serial \(c.serial)")
                }
                if let p = client.pointer(head: head) {
                    print("  pointer \(p.x),\(p.y) \(p.visible ? "visible" : "hidden")")
                }
            }
        }
    }

    struct Size: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask the guest for a scanout size (sent as display info / EDID; the guest driver decides).")
        @OptionGroup var vm: VMSelection
        @Option(help: "Scanout.") var scanout: UInt32 = 0
        @Option var width: Int
        @Option var height: Int
        @Option(help: "Seconds to wait for the guest to switch.") var timeout: Double = 15
        func run() async throws {
            let remote = try vm.remote()
            let client = try DisplayClient(run: remote.record.run)
            defer { client.close() }
            _ = try? await client.nextFrame(head: scanout, timeout: .seconds(3))
            try client.requestSize(head: scanout, width: width, height: height)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let s = client.scanout(head: scanout), s.width == width, s.height == height {
                    print("\(width)x\(height)")
                    return
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            let now = client.scanout(head: scanout).map { "\($0.width)x\($0.height)" } ?? "unknown"
            throw ValidationError("requested \(width)x\(height); scanout is still \(now)")
        }
    }
}
