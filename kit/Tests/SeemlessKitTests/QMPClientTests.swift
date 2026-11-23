import Darwin
import Foundation
import Testing
@testable import SeemlessKit

/// A scripted QMP server on a unix socket, running on its own thread.
/// `respond` maps an incoming command name to the lines to send back
/// (`$ID` is replaced with the request id).
final class FakeQMPServer: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var _received: [String] = []
    var received: [String] { lock.withLock { _received } }
    let greeting: String
    let respond: @Sendable (String) -> [String]

    init(greeting: String = #"{"QMP": {"version": {"qemu": {"major": 10, "minor": 0, "micro": 12}}, "capabilities": []}}"#,
         respond: @escaping @Sendable (String) -> [String]) throws {
        path = "/tmp/seemless-qmp-\(UUID().uuidString.prefix(8)).sock"
        listenFD = try UnixSocket.listen(path: path)
        self.greeting = greeting
        self.respond = respond
        Thread { [self] in self.serve() }.start()
    }

    var url: URL { URL(filePath: path) }

    private func serve() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        send(fd, greeting)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      let name = msg["execute"]?.stringValue else { continue }
                lock.withLock { _received.append(name) }
                let id = msg["id"]?.stringValue ?? ""
                for reply in respond(name) {
                    if reply == "CLOSE" { return }
                    send(fd, reply.replacingOccurrences(of: "$ID", with: id))
                }
            }
        }
    }

    private func send(_ fd: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    deinit {
        close(listenFD)
        unlink(path)
    }
}

@Suite struct QMPClientTests {
    static func standard(_ name: String) -> [String] {
        switch name {
        case "qmp_capabilities": return [#"{"return": {}, "id": "$ID"}"#]
        case "query-status": return [#"{"return": {"running": true, "status": "running"}, "id": "$ID"}"#]
        case "stop":
            return [#"{"timestamp": {"seconds": 1700000000, "microseconds": 500000}, "event": "STOP"}"#,
                    #"{"return": {}, "id": "$ID"}"#]
        case "bogus": return [#"{"error": {"class": "CommandNotFound", "desc": "The command bogus has not been found"}, "id": "$ID"}"#]
        case "quit": return [#"{"return": {}, "id": "$ID"}"#, "CLOSE"]
        default: return [#"{"return": {}, "id": "$ID"}"#]
        }
    }

    @Test func handshakeAndQueryStatus() async throws {
        let server = try FakeQMPServer(respond: Self.standard)
        let qmp = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        #expect(await qmp.serverInfo["version"]?["qemu"]?["major"]?.intValue == 10)
        let status = try await qmp.queryStatus()
        #expect(status == .init(running: true, state: "running"))
        #expect(server.received == ["qmp_capabilities", "query-status"])
        await qmp.close()
    }

    @Test func eventsArriveSeparatelyFromReplies() async throws {
        let server = try FakeQMPServer(respond: Self.standard)
        let qmp = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        try await qmp.stop()
        var iterator = qmp.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.name == "STOP")
        #expect(event?.timestamp == 1_700_000_000.5)
        await qmp.close()
        _ = server
    }

    @Test func commandErrorsAreThrown() async throws {
        let server = try FakeQMPServer(respond: Self.standard)
        let qmp = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        await #expect(throws: QMPError.self) { try await qmp.execute("bogus") }
        do {
            try await qmp.execute("bogus")
        } catch let QMPError.command(_, cls, _) {
            #expect(cls == "CommandNotFound")
        }
        await qmp.close()
        _ = server
    }

    @Test func quitClosesWithoutError() async throws {
        let server = try FakeQMPServer(respond: Self.standard)
        let qmp = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        await qmp.quit()
        // The stream finishes when the peer closes.
        for await _ in qmp.events {}
        #expect(await qmp.isConnected == false)
        await #expect(throws: QMPError.disconnected) { try await qmp.queryStatus() }
        _ = server
    }

    @Test func pendingCommandFailsWhenPeerDisappears() async throws {
        let server = try FakeQMPServer(respond: { name in
            name == "qmp_capabilities" ? [#"{"return": {}, "id": "$ID"}"#] : ["CLOSE"]
        })
        let qmp = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        await #expect(throws: QMPError.disconnected) { try await qmp.queryStatus() }
        _ = server
    }

    @Test func rejectsNonQMPPeer() async throws {
        let server = try FakeQMPServer(greeting: "SSH-2.0-OpenSSH", respond: { _ in [] })
        await #expect(throws: QMPError.self) {
            _ = try await QMPClient.connect(socket: server.url, timeout: .seconds(2))
        }
        _ = server
    }

    @Test func connectTimesOutWhenNobodyListens() async throws {
        let path = URL(filePath: "/tmp/seemless-nobody-\(UUID().uuidString.prefix(8)).sock")
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await QMPClient.connect(socket: path, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
