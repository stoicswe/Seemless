import Foundation
import Testing
@testable import SeemlessKit

@Suite struct QuarantineTests {
    private func arguments(_ config: VMConfig) -> [String] {
        let stack = HostStack(prefix: URL(filePath: "/nonexistent"))
        let files = VMFiles(directory: URL(filePath: "/tmp/q-vm"))
        let options = LaunchOptions(removableDrives: [RemovableDrive(id: "win", file: URL(filePath: "/tmp/win.iso"))])
        return QEMUCommand(config: config, stack: stack, files: files,
                           run: RunPaths(directory: URL(filePath: "/tmp/q-run")), options: options).arguments
    }

    private func config(_ q: Quarantine?) -> VMConfig {
        VMConfig(name: "q", network: .user, portForwards: [.init(proto: .tcp, hostPort: 3389, guestPort: 3389)],
                 media: [.init(path: "/tmp/tools.iso", kind: .cdrom)], quarantine: q)
    }

    @Test func aNormalVMHasEveryDevice() {
        let a = arguments(config(nil)).joined(separator: " ")
        #expect(a.contains("virtio-net-pci"))
        #expect(a.contains("hostfwd="))
        #expect(a.contains("virtio-serial-pci"))
        #expect(a.contains("usb-audio"))
        #expect(a.contains("/tmp/tools.iso"))
    }

    @Test func anIsolatedVMHasOnlyKeyboardMouseAndDisplay() {
        let a = arguments(config(.isolated)).joined(separator: " ")
        #expect(!a.contains("-netdev"))
        #expect(!a.contains("virtio-net-pci"))
        #expect(!a.contains("hostfwd="))
        #expect(!a.contains("virtio-serial-pci"))
        #expect(!a.contains("agent.sock"))
        #expect(!a.contains("-audiodev"))
        #expect(!a.contains("/tmp/tools.iso"))
        // Always on: keyboard, pointer, display.
        #expect(a.contains("usb-kbd"))
        #expect(a.contains("usb-tablet"))
        #expect(a.contains("virtio-ramfb"))
        // A drive given for this launch only (the image build's installer) still goes in.
        #expect(a.contains("/tmp/win.iso"))
    }

    @Test func eachConnectionAddsOnlyItsDevice() {
        let net = arguments(config(Quarantine(network: true))).joined(separator: " ")
        #expect(net.contains("virtio-net-pci") && !net.contains("virtio-serial-pci") && !net.contains("-audiodev"))

        let agent = arguments(config(Quarantine(agent: true))).joined(separator: " ")
        #expect(agent.contains("virtio-serial-pci") && !agent.contains("virtio-net-pci"))

        let audio = arguments(config(Quarantine(audio: true))).joined(separator: " ")
        #expect(audio.contains("usb-audio") && !audio.contains("virtio-net-pci"))

        let files = arguments(config(Quarantine(files: true))).joined(separator: " ")
        #expect(files.contains("/tmp/tools.iso") && !files.contains("virtio-serial-pci"))
    }

    @Test func clipboardNeedsTheAgentChannel() {
        var c = config(Quarantine(clipboardToGuest: true, clipboardToHost: true))
        #expect(!c.allows(.clipboardToGuest))
        #expect(!c.allows(.clipboardToHost))
        c.quarantine?.agent = true
        #expect(c.allows(.clipboardToGuest))
        #expect(c.allows(.clipboardToHost))
        c.quarantine?.clipboardToHost = false
        #expect(!c.allows(.clipboardToHost))
    }

    @Test func aNormalVMAllowsEverything() {
        let c = config(nil)
        #expect(VMConfig.Connection.allCases.allSatisfy { c.allows($0) })
        #expect(c.effectiveNetwork == .user)
        #expect(config(.isolated).effectiveNetwork == .none)
    }

    @Test func missingFieldsDecodeAsOff() throws {
        // A config written before a connection existed must not switch it on.
        let q = try JSONDecoder().decode(Quarantine.self, from: Data(#"{"network": true}"#.utf8))
        #expect(q == Quarantine(network: true))
        let c = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(config(.isolated)))
        #expect(c.quarantine == .isolated)
        let normal = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(config(nil)))
        #expect(normal.quarantine == nil)
    }
}
