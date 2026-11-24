import Foundation
import Testing
@testable import SeemlessKit

/// WP4.4: the host's agent link against the mock agent.
@Suite struct AgentLinkTests {
    private func script(_ json: String) throws -> MockAgentScript {
        try JSONDecoder().decode(MockAgentScript.self, from: Data(json.utf8))
    }

    private func signedIn(_ user: String, locked: Bool = false) -> String {
        """
        {"capabilities": ["core.v1", "system.v1"],
         "steps": [{"send": {"sessionState": {"loggedOn": true, "locked": \(locked), "user": "\(user)"}}}]}
        """
    }

    /// Serves `script` on a short socket path, runs `body` with the socket.
    private func withMock(_ script: MockAgentScript, connections: Int = 1,
                          _ body: (URL, MockAgent) async throws -> Void) async throws {
        let dir = URL(filePath: "/tmp/sll-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appending(path: "agent.sock")
        let mock = MockAgent(script: script)
        let server = Task { try await mock.serve(socket: socket, connections: connections) }
        defer { server.cancel() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await body(socket, mock)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private func config(_ socket: URL, setup: Bool, appearance: HostAppearance = .dark) -> AgentLink.Configuration {
        var c = AgentLink.Configuration(socket: socket, finishSetupWhenSignedIn: setup)
        c.appearance = { appearance }
        c.helloTimeout = .seconds(3)
        c.now = { Date(timeIntervalSince1970: 1_795_000_000) }
        return c
    }

    @Test func signedInDesktopEndsTheOfflineSetupOnce() async throws {
        try await withMock(try script(signedIn("Seemless")), connections: 2) { socket, mock in
            let finished = Flag()
            let link = AgentLink(config(socket, setup: true)) { finished.hit() }
            let r = try #require(await link.sync())
            #expect(r.session?.user == "Seemless")
            #expect(r.timeSynced)
            #expect(r.appearanceSent == .dark)
            #expect(finished.count == 1)
            // The mock saw the clock and the appearance.
            let bodies = await mock.messages.compactMap(\.body)
            #expect(bodies.contains { if case .timeSync(let t) = $0 { t.unixNanos == 1_795_000_000_000_000_000 } else { false } })
            #expect(bodies.contains { if case .setHostInfo(let h) = $0 { h.appearance == .dark } else { false } })
            // A second sync does not end the setup again.
            _ = await link.sync()
            #expect(finished.count == 1)
        }
    }

    @Test func oobeLockedOrOldAgentsDoNotEndTheSetup() async throws {
        for json in [signedIn("defaultuser0"), signedIn("Seemless", locked: true),
                     #"{"capabilities": ["core.v1"], "steps": [{"send": {"sessionState": {"loggedOn": true, "user": "Seemless"}}}]}"#] {
            try await withMock(try script(json)) { socket, mock in
                let finished = Flag()
                let link = AgentLink(config(socket, setup: true)) { finished.hit() }
                let r = try #require(await link.sync())
                #expect(finished.count == 0, "\(json)")
                if json.contains("system.v1") {
                    #expect(r.timeSynced)
                } else {
                    // A WP4.2 agent: nothing is sent to it.
                    #expect(!r.timeSynced && r.appearanceSent == nil)
                    #expect(await mock.messages.isEmpty)
                }
            }
        }
    }

    @Test func missingAgentChannelIsQuiet() async {
        let link = AgentLink(config(URL(filePath: "/tmp/sll-missing-\(UUID().uuidString.prefix(6)).sock"), setup: true)) {}
        #expect(await link.sync() == nil)
        #expect(await AgentLink.requestShutdown(socket: URL(filePath: "/tmp/sll-none.sock")) == false)
    }

    @Test func shutdownIsAcknowledged() async throws {
        try await withMock(try script(#"{"capabilities": ["core.v1", "system.v1"]}"#)) { socket, mock in
            #expect(await AgentLink.requestShutdown(socket: socket, mode: .restart))
            let bodies = await mock.messages.compactMap(\.body)
            #expect(bodies.contains { if case .shutdown(let s) = $0 { s.mode == .restart } else { false } })
        }
        try await withMock(try script(#"{"capabilities": ["core.v1"]}"#)) { socket, _ in
            #expect(await AgentLink.requestShutdown(socket: socket) == false, "no system.v1: ACPI instead")
        }
    }

    @Test func signedInDesktopRule() {
        func s(_ loggedOn: Bool, _ locked: Bool, _ user: String, secure: Bool = false) -> Seemless_V1_SessionState {
            var st = Seemless_V1_SessionState()
            st.loggedOn = loggedOn; st.locked = locked; st.user = user; st.secureDesktop = secure
            return st
        }
        #expect(AgentLink.isSignedInDesktop(s(true, false, "Seemless")))
        #expect(!AgentLink.isSignedInDesktop(s(false, false, "")))
        #expect(!AgentLink.isSignedInDesktop(s(true, true, "Seemless")))
        #expect(!AgentLink.isSignedInDesktop(s(true, false, "defaultuser0")))
        #expect(!AgentLink.isSignedInDesktop(s(true, false, "DefaultUser1")))
        #expect(!AgentLink.isSignedInDesktop(s(true, false, "Seemless", secure: true)))
        #expect(!AgentLink.isSignedInDesktop(s(true, false, "  ")))
    }
}
