import Foundation
import SwiftProtobuf
import Testing
@testable import SeemlessKit

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Golden frames (shared with guest/agent/crates/proto/src/golden.rs)

@Suite struct AgentGoldenFrameTests {
    static func hello(_ role: Seemless_V1_Role, _ build: String, _ caps: [String]) -> Seemless_V1_Envelope.OneOf_Body {
        .hello(AgentHandshake.hello(role: role, build: build, capabilities: caps))
    }

    static func window(_ id: UInt64, owner: UInt64, kind: Seemless_V1_WindowKind, rect: (Int32, Int32, UInt32, UInt32),
                       title: String, state: Seemless_V1_WindowShowState,
                       flags: (Bool, Bool, Bool), icon: UInt64) -> Seemless_V1_Window {
        var w = Seemless_V1_Window()
        w.id = id
        w.ownerID = owner
        w.kind = kind
        w.rect = .with { $0.x = rect.0; $0.y = rect.1; $0.width = rect.2; $0.height = rect.3 }
        w.title = title
        w.appKey = "notepad"
        w.pid = 4242
        w.state = state
        w.flags = .with { $0.resizable = flags.0; $0.topmost = flags.1; $0.hasAlpha_p = flags.2 }
        w.iconID = icon
        return w
    }

    /// The same envelopes as `golden.rs`, in the same order.
    static let cases: [(String, Seemless_V1_Envelope)] = [
        ("hello-host", .init(seq: 1, body: hello(.host, "seemless-host test", ["core.v1", "windows.v1"]))),
        ("hello-guest", .init(seq: 1, body: hello(.guestService, "seemless-agent test", ["core.v1"]))),
        ("ping", .init(seq: 2, body: .ping(.with { $0.nonce = 0x1122_3344_5566_7788 }))),
        ("pong", .init(seq: 2, replyTo: 2, body: .pong(.with { $0.nonce = 0x1122_3344_5566_7788 }))),
        ("guest-info", .init(seq: 3, replyTo: 5, body: .guestInfo(.with {
            $0.osBuild = "10.0.26300.9457"
            $0.driverVersions = [.with { $0.name = "viogpu3d"; $0.version = "0.1" },
                                 .with { $0.name = "vioserial"; $0.version = "100.95" }]
            $0.agentVersion = "0.0.1"
            $0.gpuAdapter = "Virtio GPU 3D — Neptune"
        }))),
        ("window-snapshot", .init(seq: 4, body: .windowSnapshot(.with {
            $0.windows = [
                window(1, owner: 0, kind: .normal, rect: (-8, 0, 1936, 1048), title: "Notepad — Ünïcode",
                       state: .maximized, flags: (true, false, false), icon: 77),
                window(2, owner: 1, kind: .dialog, rect: (400, 300, 480, 200), title: "Save As",
                       state: .normal, flags: (false, true, true), icon: 0),
            ]
        }))),
        ("error", .init(seq: 5, replyTo: 9, body: .error(.with { $0.code = .unsupported; $0.message = "no such request" }))),
    ]

    @Test(arguments: cases.map(\.0))
    func swiftEncodesAndDecodesTheSharedGoldenFrame(name: String) throws {
        let envelope = try #require(Self.cases.first { $0.0 == name }).1
        let golden = try Data(contentsOf: repoRoot.appending(path: "proto/testdata/\(name).frame"))
        #expect(try AgentFrame.encode(envelope) == golden, "Swift and Rust must produce identical bytes")
        var decoder = AgentFrame.Decoder(channel: .control)
        let frames = try decoder.push(golden)
        #expect(frames.count == 1)
        #expect(try Seemless_V1_Envelope(serializedBytes: frames[0].payload) == envelope)
    }

    @Test func everyGoldenFileHasASwiftCase() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: repoRoot.appending(path: "proto/testdata").path)
            .filter { $0.hasSuffix(".frame") }.map { String($0.dropLast(6)) }
        #expect(Set(files) == Set(Self.cases.map(\.0)))
    }
}

// MARK: - Framing and handshake

@Suite struct AgentFrameTests {
    @Test func roundTripsSplitAtEveryByte() throws {
        var wire = AgentFrame.encode(payload: Data("hello".utf8))
        wire += AgentFrame.encode(payload: Data())
        wire += AgentFrame.encode(payload: Data(repeating: 7, count: 300))
        for split in 0...wire.count {
            var d = AgentFrame.Decoder(channel: .control)
            var frames = try d.push(wire.prefix(split))
            frames += try d.push(wire.dropFirst(split))
            #expect(frames.map(\.payload) == [Data("hello".utf8), Data(), Data(repeating: 7, count: 300)], "split \(split)")
            #expect(d.buffered == 0)
        }
    }

    @Test func headerIsLittleEndianPayloadLength() {
        #expect(AgentFrame.encode(.bulk, payload: Data("abc".utf8)) == Data([3, 0, 0, 0, 1, 0x61, 0x62, 0x63]))
    }

    @Test func oversizedFailsOnTheHeaderAndPoisonsTheDecoder() throws {
        var d = AgentFrame.Decoder(channel: .control)
        let n = UInt32(AgentFrame.maxControlPayload + 1)
        let header = Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24), 0])
        #expect(throws: AgentFrame.FrameError.oversized(length: Int(n), max: AgentFrame.maxControlPayload)) { try d.push(header) }
        #expect(throws: AgentFrame.FrameError.reset) { try d.push(AgentFrame.encode(payload: Data("x".utf8))) }
    }

    @Test func framesBeforeABadOneAreKept() {
        var wire = AgentFrame.encode(payload: Data("good".utf8))
        wire += Data([0, 0, 0, 0, 9])
        var d = AgentFrame.Decoder(channel: .control)
        let out = d.decode(wire)
        #expect(out.frames.map(\.payload) == [Data("good".utf8)])
        #expect(out.error == .unknownKind(9))
    }

    @Test func bulkKindOnlyOnTheBulkChannel() throws {
        var bulk = AgentFrame.Decoder(channel: .bulk)
        #expect(try bulk.push(AgentFrame.encode(.bulk, payload: Data(count: AgentFrame.maxControlPayload + 1))).count == 1)
        var control = AgentFrame.Decoder(channel: .control)
        #expect(throws: AgentFrame.FrameError.kindNotAllowed(.bulk, .control)) {
            try control.push(AgentFrame.encode(.bulk, payload: Data("x".utf8)))
        }
        var unknown = AgentFrame.Decoder(channel: .bulk)
        #expect(throws: AgentFrame.FrameError.unknownKind(9)) { try unknown.push(Data([0, 0, 0, 0, 9])) }
    }
}

@Suite struct AgentHandshakeTests {
    let host = AgentHandshake.hello(role: .host, build: "host", capabilities: ["core.v1", "windows.v1", "clipboard.v1"])

    func guest(_ caps: [String], build: String = "g") -> Seemless_V1_Hello {
        AgentHandshake.hello(role: .guestService, build: build, capabilities: caps)
    }

    @Test func intersectsCapabilities() throws {
        let n = try AgentHandshake.negotiate(local: host, remote: guest(["windows.v1", "core.v1", "future.v9"], build: "agent 0.0.1"))
        #expect(n.capabilities == ["core.v1", "windows.v1"])
        #expect(n.has("windows.v1") && !n.has("clipboard.v1"))
        #expect(n.peerBuild == "agent 0.0.1")
    }

    @Test func minorDifferencesAreFineMajorIsNot() throws {
        var g = guest(["core.v1"])
        g.protocolMinor = 7
        #expect(try AgentHandshake.negotiate(local: host, remote: g).peerMinor == 7)
        g.protocolMajor = 2
        #expect(throws: AgentHandshake.HandshakeError.majorMismatch(local: 1, remote: 2)) {
            try AgentHandshake.negotiate(local: host, remote: g)
        }
    }

    @Test func rejectsBadHellos() throws {
        let sameRole = AgentHandshake.hello(role: .host, build: "g", capabilities: [])
        #expect(throws: AgentHandshake.HandshakeError.wrongRole(1)) { try AgentHandshake.negotiate(local: host, remote: sameRole) }
        var unknown = guest([])
        unknown.role = .UNRECOGNIZED(99)
        #expect(throws: AgentHandshake.HandshakeError.wrongRole(99)) { try AgentHandshake.negotiate(local: host, remote: unknown) }
        for bad in [guest([], build: String(repeating: "x", count: 257)), guest(["Core.v1"]), guest([""]),
                    guest([String(repeating: "a", count: 65)]), guest((0...64).map { "c\($0)" })] {
            #expect(throws: AgentHandshake.HandshakeError.self) { try AgentHandshake.negotiate(local: host, remote: bad) }
        }
    }

    @Test func bodyNamesAreTheJSONNames() {
        #expect(Seemless_V1_Envelope(seq: 1, body: .getGuestInfo(.init())).bodyName == "getGuestInfo")
        #expect(Seemless_V1_Envelope().bodyName == "")
    }
}

// MARK: - AgentClient <-> MockAgent round trips

/// Starts a mock agent on a fresh short socket path (sun_path is 104 bytes)
/// and connects a client with fast test timings.
private func withMock(_ script: MockAgentScript, options: AgentClient.Options? = nil,
                      _ body: (AgentClient, MockAgent) async throws -> Void) async throws {
    let dir = URL(filePath: "/tmp/sla-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let socket = dir.appending(path: "agent.sock")
    let mock = MockAgent(script: script)
    let server = Task { try await mock.serve(socket: socket) }
    var opts = options ?? AgentClient.Options()
    if options == nil {
        opts.capabilities = ["core.v1", "windows.v1", "clipboard.v1"]
        opts.helloTimeout = .seconds(5)
        opts.requestTimeout = .seconds(5)
    }
    let client: AgentClient
    do {
        client = try await AgentClient.connect(socket: socket, options: opts, connectTimeout: .seconds(5))
    } catch {
        server.cancel()
        throw error
    }
    do {
        try await body(client, mock)
    } catch {
        await client.close()
        _ = try? await server.value
        throw error
    }
    await client.close()
    try await server.value  // the mock ends its session when the host goes, without error
}

private func script(_ json: String) throws -> MockAgentScript {
    try JSONDecoder().decode(MockAgentScript.self, from: Data(json.utf8))
}

/// Records `client.states` from one consumer (an AsyncStream has a single
/// consumer; iterating it again from a new loop is not reliable).
private actor StateLog {
    private var states: [AgentClient.State] = []
    private var cursor = 0
    private var task: Task<Void, Never>?

    init(_ client: AgentClient) {
        let stream = client.states
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<AgentClient.State>) {
        task = Task { for await s in stream { self.add(s) } }
    }

    private func add(_ s: AgentClient.State) { states.append(s) }

    /// The next state after those already returned, skipping `.ready`.
    func next(within: Duration = .seconds(5)) async -> AgentClient.State? {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            while cursor < states.count {
                let s = states[cursor]
                cursor += 1
                if case .ready = s { continue }
                return s
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@Suite struct AgentClientTests {
    @Test func handshakeNegotiatesAndGuestInfoRoundTrips() async throws {
        let s = try script("""
            {"build": "mock 7", "capabilities": ["core.v1", "windows.v1", "apps.v1"],
             "guestInfo": {"osBuild": "10.0.26300.9457", "agentVersion": "mock", "gpuAdapter": "Virtio GPU 3D",
                           "driverVersions": [{"name": "vioserial", "version": "100.95"}]}}
            """)
        try await withMock(s) { (client, _) async throws in
            let n = try #require(await client.negotiated)
            #expect(n.peerBuild == "mock 7")
            #expect(n.peerRole == .guestService)
            #expect(n.capabilities == ["core.v1", "windows.v1"])
            let info = try await client.guestInfo()
            #expect(info.osBuild == "10.0.26300.9457")
            #expect(info.driverVersions.map(\.name) == ["vioserial"])
        }
    }

    @Test func guestInfoIsSanitized() {
        var info = Seemless_V1_GuestInfo()
        info.osBuild = "Windows\u{1B}[31m 11\n" + String(repeating: "x", count: 1000)
        info.driverVersions = (0..<100).map { i in .with { $0.name = "d\(i)"; $0.version = "1\u{0}" } }
        let s = AgentClient.sanitized(info)
        #expect(s.osBuild.hasPrefix("Windows[31m 11x"))
        #expect(s.osBuild.unicodeScalars.count == AgentClient.maxGuestInfoText)
        #expect(s.driverVersions.count == AgentClient.maxGuestInfoDrivers)
        #expect(s.driverVersions[0].version == "1")
    }

    @Test func scriptedEventsArriveInOrderAndHostMessagesAreSeen() async throws {
        let s = try script("""
            {"steps": [
              {"send": {"sessionState": {"loggedOn": true, "user": "Seemless"}}},
              {"send": {"windowSnapshot": {"windows": [{"id": "1", "title": "Ünïcode — Notepad", "rect": {"x": -8, "width": 640, "height": 480}}]}}},
              {"expect": "setHostInfo"},
              {"send": {"windowRemoved": {"id": "1"}}}
            ]}
            """)
        try await withMock(s) { (client, mock) async throws in
            var events = client.events.makeAsyncIterator()
            let first = try #require(await events.next())
            guard case .sessionState(let session) = first.body else { Issue.record("got \(first.bodyName)"); return }
            #expect(session.loggedOn && session.user == "Seemless")
            let second = try #require(await events.next())
            guard case .windowSnapshot(let snap) = second.body else { Issue.record("got \(second.bodyName)"); return }
            #expect(snap.windows.first?.title == "Ünïcode — Notepad")
            #expect(snap.windows.first?.rect.x == -8)

            // Every host request gets exactly one reply: Ack for commands.
            let reply = try await client.request(.setHostInfo(.with { $0.appearance = .dark; $0.locale = "en-US" }))
            #expect(reply.bodyName == "ack")
            let activated = try await client.request(.activate(.with { $0.id = 1 }))
            guard case .activated(let a) = activated.body else { Issue.record("got \(activated.bodyName)"); return }
            #expect(a.id == 1)
            let third = try #require(await events.next())
            #expect(third.bodyName == "windowRemoved")
            let sent = await mock.messages
            #expect(sent.map(\.bodyName) == ["setHostInfo", "activate"])
            guard case .setHostInfo(let info) = sent.first?.body else { return }
            #expect(info.appearance == .dark)
        }
    }

    @Test func queriesGetScriptedRepliesOrUnsupported() async throws {
        let s = try script("""
            {"replies": {"listApps": {"appList": {"apps": [{"appKey": "notepad", "name": "Notepad"}]}}}}
            """)
        try await withMock(s) { (client, _) async throws in
            let reply = try await client.request(.listApps(.init()))
            guard case .appList(let list) = reply.body else { Issue.record("got \(reply.bodyName)"); return }
            #expect(list.apps.map(\.name) == ["Notepad"])
            await #expect(throws: AgentError.remote(.unsupported, "the mock agent has no reply for hitTest")) {
                try await client.request(.hitTest(.init()))
            }
        }
    }

    @Test func unansweredRequestsTimeOut() async throws {
        var opts = AgentClient.Options()
        opts.requestTimeout = .milliseconds(200)
        try await withMock(try script(#"{"ignore": ["listApps"]}"#), options: opts) { (client, _) async throws in
            let start = ContinuousClock.now
            await #expect(throws: AgentError.timeout("listApps")) { try await client.request(.listApps(.init())) }
            #expect(ContinuousClock.now - start < .seconds(2))
            // The connection is still usable afterwards.
            let os = try await client.guestInfo().osBuild
            #expect(os == "mock")
        }
    }

    @Test func silentAgentBecomesUnresponsiveThenRecovers() async throws {
        var opts = AgentClient.Options()
        opts.heartbeatInterval = .milliseconds(50)
        opts.missedPings = 3
        let s = try script(#"{"steps": [{"pings": false}, {"sleepMs": 400}, {"pings": true}]}"#)
        try await withMock(s, options: opts) { (client, _) async throws in
            let log = StateLog(client)
            let lost = await log.next()
            #expect(lost == .unresponsive)
            let back = await log.next()
            #expect(back == .responsive)
        }
    }

    @Test func agentRestartIsReported() async throws {
        let s = try script(#"{"steps": [{"sleepMs": 100}, {"hello": true}]}"#)
        try await withMock(s) { (client, _) async throws in
            guard case .peerRestarted(let n) = await StateLog(client).next() else { Issue.record("no restart"); return }
            #expect(n.peerBuild.hasPrefix("seemless-mock-agent"))
            // Still working after the restart.
            #expect(try await client.guestInfo().osBuild == "mock")
        }
    }

    // The guest is untrusted: anything malformed resets the channel.

    @Test func oversizedFrameFromGuestClosesTheChannel() async throws {
        let oversized = Data([0x01, 0x00, 0x20, 0x00, 0x00]).base64EncodedString()  // 2 MiB + 1 declared
        try await withMock(try script(#"{"steps": [{"raw": "\#(oversized)"}]}"#)) { (client, _) async throws in
            guard case .closed(let why) = await StateLog(client).next() else { Issue.record("not closed"); return }
            #expect(why.contains("framing error"))
            await #expect(throws: AgentError.self) { try await client.guestInfo() }
        }
    }

    @Test func garbageEnvelopeFromGuestClosesTheChannel() async throws {
        let garbage = AgentFrame.encode(payload: Data([0xFF, 0xFF, 0xFF, 0xFF])).base64EncodedString()
        try await withMock(try script(#"{"steps": [{"raw": "\#(garbage)"}]}"#)) { (client, _) async throws in
            guard case .closed(let why) = await StateLog(client).next() else { Issue.record("not closed"); return }
            #expect(why.contains("malformed envelope"))
        }
    }

    @Test func incompatibleGuestIsRejectedAtConnect() async throws {
        await #expect(throws: AgentHandshake.HandshakeError.majorMismatch(local: 1, remote: 2)) {
            try await withMock(try script(#"{"protocolMajor": 2}"#)) { _, _ in }
        }
        await #expect(throws: AgentHandshake.HandshakeError.self) {
            try await withMock(try script(#"{"capabilities": ["NOT VALID"]}"#)) { _, _ in }
        }
    }

    @Test func badScriptMessagesAreReported() throws {
        #expect(throws: MockAgentError.self) { try MockAgent.body(.object(["noSuchMessage": .object([:])]), what: "send") }
        #expect(throws: DecodingError.self) { try script(#"{"steps": [{"explode": true}]}"#) }
    }

    @Test func shippedExampleScriptParses() throws {
        let s = try MockAgentScript.load(repoRoot.appending(path: "proto/mock/notepad.json"))
        for case .send(let json) in s.steps { _ = try MockAgent.body(json, what: "send") }
        #expect(s.steps.count == 4)
    }
}
