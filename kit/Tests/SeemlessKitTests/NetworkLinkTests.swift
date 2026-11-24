import Foundation
import Testing
@testable import SeemlessKit

@Suite struct NetworkLinkTests {
    private func tempRun() throws -> RunPaths {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nl-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RunPaths(directory: dir)
    }

    @Test func setLinkTargetsTheNetdevQEMUCommandCreates() {
        #expect(NetworkLink.setLinkArguments(up: false) == ["name": .string("n0"), "up": .bool(false)])
        #expect(NetworkLink.setLinkArguments(up: true)["up"] == .bool(true))
    }

    @Test func netdevIDMatchesTheCommandLine() throws {
        // QEMUCommand names the netdev `n0`; set_link must use the same id.
        let config = VMConfig(name: "t", network: .user)
        let layout = StorageLayout(root: FileManager.default.temporaryDirectory.appending(path: "nl-root"))
        let stack = HostStack(prefix: URL(filePath: "/nonexistent"))
        let cmd = QEMUCommand(config: config, stack: stack, files: VMFiles(directory: layout.vm(named: "t")),
                              run: RunPaths(directory: URL(filePath: "/tmp/r")), options: LaunchOptions())
        #expect(cmd.arguments.contains { $0.hasPrefix("user,id=\(NetworkLink.netdevID)") })
    }

    @Test func aRunStartsConnectedAndRecordsChanges() throws {
        let run = try tempRun()
        #expect(NetworkLink.isConnected(run: run))
        try NetworkLink.record(connected: false, run: run)
        #expect(!NetworkLink.isConnected(run: run))
        try NetworkLink.record(connected: true, run: run)
        #expect(NetworkLink.isConnected(run: run))
    }

    @Test func setSendsSetLinkOverQMP() async throws {
        let server = try FakeQMPServer(respond: QMPClientTests.standard)
        let qmp = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        let run = try tempRun()
        try await NetworkLink.set(connected: false, qmp: qmp, run: run)
        await qmp.close()
        #expect(!NetworkLink.isConnected(run: run))
        // The fake server records command names; the arguments are checked
        // in setLinkTargetsTheNetdevQEMUCommandCreates.
        #expect(server.received.contains("set_link"))
    }

    @Test func offlineFlagDefaultsOffAndRoundTrips() throws {
        // Older config.json files have no field: they decode as online.
        var config = VMConfig(name: "t")
        let old = try JSONEncoder().encode(config)
        var json = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        json.removeValue(forKey: "offlineUntilSetupDone")
        let decoded = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.offlineUntilSetupDone == false)

        config.offlineUntilSetupDone = true
        let again = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(config))
        #expect(again.offlineUntilSetupDone)
    }
}
