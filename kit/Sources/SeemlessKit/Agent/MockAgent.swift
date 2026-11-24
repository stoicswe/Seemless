import Darwin
import Foundation
import SwiftProtobuf

/// What a `MockAgent` does, read from JSON (`seemlessctl mock-agent --script`).
///
/// Message bodies use protobuf's JSON mapping of an `Envelope` body, e.g.
/// `{"windowSnapshot": {"windows": [{"id": "1", "title": "Notepad"}]}}`.
///
/// ```json
/// {
///   "build": "mock 1",
///   "capabilities": ["core.v1", "windows.v1"],
///   "guestInfo": {"osBuild": "10.0.26300.9457", "agentVersion": "mock"},
///   "replies": {"listApps": {"appList": {"apps": [{"appKey": "notepad", "name": "Notepad"}]}}},
///   "ignore": ["hitTest"],
///   "steps": [
///     {"send": {"sessionState": {"loggedOn": true, "user": "Seemless"}}},
///     {"expect": "setHostInfo", "timeoutMs": 5000},
///     {"sleepMs": 200},
///     {"pings": false},
///     {"hello": true},
///     {"raw": "<base64 bytes, sent as is>"},
///     {"disconnect": true}
///   ]
/// }
/// ```
public struct MockAgentScript: Sendable, Decodable {
    public var build = "seemless-mock-agent \(Seemless.version)"
    public var capabilities = [AgentHandshake.Capability.core]
    /// Overrides the advertised major version (to test mismatches).
    public var protocolMajor: UInt32?
    /// Reply to `getGuestInfo`, as GuestInfo JSON.
    public var guestInfo: JSONValue?
    /// Request body name -> reply body, as Envelope-body JSON.
    public var replies: [String: JSONValue] = [:]
    /// Requests that are never answered (to test timeouts).
    public var ignore: [String] = []
    public var steps: [Step] = []
    /// Guest display size for the simulated window manager
    /// (`{"windowManager": {"width": 800, "height": 600}}`). When set, the mock
    /// answers `HitTest`, `SetWindowRect` and `WindowCommand` like Windows
    /// would and reports the results (`SimulatedWindowManager`).
    public var windowManager: GuestRect?
    /// Loopback TCP port for the Zen stand-in helper in the guest
    /// (`{"guestHelper": {"port": 47800}}`, `GuestHelperMessage`): its real
    /// windows are reported to the host, and the host's `SetWindowRect` and
    /// `WindowCommand` for them are passed on to it.
    public var guestHelperPort: UInt16?

    public init(steps: [Step] = []) { self.steps = steps }

    public enum Step: Sendable, Decodable {
        case send(JSONValue)
        case sleep(milliseconds: Int)
        case expect(String, timeoutMilliseconds: Int)
        /// Answer Pings (true) or stay silent (false).
        case pings(Bool)
        /// Send a fresh Hello, as an agent does after restarting.
        case hello
        case raw(Data)
        case disconnect

        private enum Key: String, CodingKey { case send, sleepMs, expect, timeoutMs, pings, hello, raw, disconnect }

        public init(from decoder: Swift.Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            if let v = try c.decodeIfPresent(JSONValue.self, forKey: .send) { self = .send(v) }
            else if let v = try c.decodeIfPresent(Int.self, forKey: .sleepMs) { self = .sleep(milliseconds: v) }
            else if let v = try c.decodeIfPresent(String.self, forKey: .expect) {
                self = .expect(v, timeoutMilliseconds: try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 5000)
            }
            else if let v = try c.decodeIfPresent(Bool.self, forKey: .pings) { self = .pings(v) }
            else if try c.decodeIfPresent(Bool.self, forKey: .hello) == true { self = .hello }
            else if let v = try c.decodeIfPresent(String.self, forKey: .raw) {
                guard let data = Data(base64Encoded: v) else {
                    throw DecodingError.dataCorruptedError(forKey: .raw, in: c, debugDescription: "not base64")
                }
                self = .raw(data)
            }
            else if try c.decodeIfPresent(Bool.self, forKey: .disconnect) == true { self = .disconnect }
            else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                    debugDescription: "unknown step; expected one of send, sleepMs, expect, pings, hello, raw, disconnect"))
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case build, capabilities, protocolMajor, guestInfo, replies, ignore, steps, windowManager, guestHelper }
    private struct WMSize: Decodable { var width: Int; var height: Int }
    private struct Helper: Decodable { var port: UInt16 }

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        build = try c.decodeIfPresent(String.self, forKey: .build) ?? build
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? capabilities
        protocolMajor = try c.decodeIfPresent(UInt32.self, forKey: .protocolMajor)
        guestInfo = try c.decodeIfPresent(JSONValue.self, forKey: .guestInfo)
        replies = try c.decodeIfPresent([String: JSONValue].self, forKey: .replies) ?? [:]
        ignore = try c.decodeIfPresent([String].self, forKey: .ignore) ?? []
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        if let wm = try c.decodeIfPresent(WMSize.self, forKey: .windowManager) {
            windowManager = GuestRect(x: 0, y: 0, width: wm.width, height: wm.height)
        }
        guestHelperPort = try c.decodeIfPresent(Helper.self, forKey: .guestHelper)?.port
    }

    public static func load(_ url: URL) throws -> MockAgentScript {
        try JSONDecoder().decode(MockAgentScript.self, from: Data(contentsOf: url))
    }
}

public enum MockAgentError: Error, CustomStringConvertible {
    case badMessage(String, String)
    case expectTimedOut(String)

    public var description: String {
        switch self {
        case .badMessage(let what, let why): return "script message \(what) is not valid protocol JSON: \(why)"
        case .expectTimedOut(let name): return "the host did not send \(name) in time"
        }
    }
}

/// A fake guest agent service on a unix socket: it plays QEMU's agent
/// chardev plus `seemless-agent-svc`, so `AgentClient` and everything above
/// it can be developed and tested on the Mac with no VM (docs/06).
///
/// Speaks the real framing and Hello rules, answers Pings, answers requests
/// (scripted reply, `Ack`, or `Error` UNSUPPORTED for queries it cannot
/// answer), and runs the script's steps once the host's Hello arrives.
public actor MockAgent {
    /// Requests whose reply carries data; without a scripted reply they get
    /// `Error` UNSUPPORTED rather than `Ack`.
    static let queries: Set<String> = ["getGuestInfo", "listApps", "getIcon", "hitTest", "clipboardRequest", "runCommand"]

    public let script: MockAgentScript
    private let log: @Sendable (String) -> Void

    private var fd: Int32 = -1
    private var handle: FileHandle?
    private var decoder = AgentFrame.Decoder(channel: .control)
    private var seq: UInt64 = 0
    private var answerPings = true
    private var hostHello: Seemless_V1_Hello?
    private var helloWaiters: [CheckedContinuation<Void, Never>] = []
    private var received: [Seemless_V1_Envelope] = []
    private var expectWaiters: [(name: String, from: Int, cont: CheckedContinuation<Bool, Never>)] = []
    private var connectionDone: CheckedContinuation<Void, Never>?
    private var finished = false
    private var wm: SimulatedWindowManager?
    private var helper = GuestHelperWindows()
    private var helperFD: Int32 = -1
    private var helperTask: Task<Void, Never>?

    public init(script: MockAgentScript, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.script = script
        self.log = log
    }

    /// Everything the host sent on the current connection, in order.
    public var messages: [Seemless_V1_Envelope] { received }

    /// Listens on `socket` and serves `connections` hosts one after another
    /// (nil: until cancelled). Throws on a script error.
    public func serve(socket: URL, connections: Int? = 1) async throws {
        let listener = try UnixSocket.listen(path: socket.path(percentEncoded: false))
        defer {
            Darwin.close(listener)
            unlink(socket.path(percentEncoded: false))
        }
        log("mock agent listening on \(socket.path(percentEncoded: false))")
        if let port = script.guestHelperPort {
            let l = try LoopbackTCP.listen(port: port)
            log("guest helper port 127.0.0.1:\(port) (10.0.2.2:\(port) in the guest)")
            helperTask = Task { await self.serveHelper(listener: l) }
        }
        defer { helperTask?.cancel() }
        var served = 0
        while connections.map({ served < $0 }) ?? true {
            try Task.checkCancellation()
            let client = try await Self.accept(listener)
            served += 1
            try await session(fd: client)
        }
    }

    /// `accept(2)` on its own thread, so a waiting mock holds no pool thread.
    /// Cancellation closes nothing: callers cancel by closing the listener.
    private static func accept(_ listener: Int32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            Thread {
                while true {
                    let fd = Darwin.accept(listener, nil, nil)
                    if fd >= 0 {
                        var on: Int32 = 1
                        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                        cont.resume(returning: fd)
                        return
                    }
                    if errno == EINTR { continue }
                    cont.resume(throwing: UnixSocket.Failure.system("accept", errno))
                    return
                }
            }.start()
        }
    }

    private func session(fd: Int32) async throws {
        self.fd = fd
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        decoder = AgentFrame.Decoder(channel: .control)
        seq = 0
        answerPings = true
        wm = script.windowManager.map { SimulatedWindowManager(workArea: $0) }
        hostHello = nil
        received = []
        expectCursor = 0
        finished = false
        log("host connected")

        let chunks = ByteReader.chunks(fd: fd)
        let reader = Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
            await self?.ended("host disconnected")
        }
        defer { reader.cancel() }

        try sendHello(replyTo: 0)
        await waitForHostHello()
        guard !finished else { return }
        if script.guestHelperPort != nil {
            try write(Seemless_V1_Envelope(seq: nextSeq(), body: helper.snapshot))
            log("→ windowSnapshot (\(helper.order.count) helper windows)")
        }
        do {
            try await runSteps()
        } catch {
            ended("script failed: \(error)")
            throw error
        }
        // Keep answering until the host goes away.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if finished { cont.resume() } else { connectionDone = cont }
        }
    }

    private func runSteps() async throws {
        for step in script.steps {
            guard !finished else { return }
            switch step {
            case .send(let json):
                let body = try Self.body(json, what: "send")
                wm?.observe(body)
                try write(Seemless_V1_Envelope(seq: nextSeq(), body: body))
                log("→ \(Seemless_V1_Envelope.bodyName(body))")
            case .sleep(let ms):
                try await Task.sleep(for: .milliseconds(ms))
            case .expect(let name, let timeout):
                guard await expect(name, timeout: .milliseconds(timeout)) else { throw MockAgentError.expectTimedOut(name) }
                log("✓ host sent \(name)")
            case .pings(let on):
                answerPings = on
                log(on ? "answering pings" : "ignoring pings")
            case .hello:
                try sendHello(replyTo: 0)
                log("→ hello (restart)")
            case .raw(let data):
                writeRaw(data)
                log("→ \(data.count) raw bytes")
            case .disconnect:
                log("disconnecting")
                ended("script disconnected")
                return
            }
        }
    }

    // MARK: Messages

    static func body(_ json: JSONValue, what: String) throws -> Seemless_V1_Envelope.OneOf_Body {
        do {
            let text = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
            let envelope = try Seemless_V1_Envelope(jsonString: text)
            guard let body = envelope.body else { throw MockAgentError.badMessage(what, "no message body") }
            return body
        } catch let error as MockAgentError {
            throw error
        } catch {
            throw MockAgentError.badMessage(what, "\(error)")
        }
    }

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    private func write(_ envelope: Seemless_V1_Envelope) throws {
        writeRaw(try AgentFrame.encode(envelope))
    }

    /// A failed write means the host went away: the session ends, which is
    /// not a script error.
    private func writeRaw(_ data: Data) {
        guard !finished, let handle else { return }
        do { try handle.write(contentsOf: data) } catch { ended("host disconnected") }
    }

    private func sendHello(replyTo: UInt64) throws {
        var hello = AgentHandshake.hello(role: .guestService, build: script.build, capabilities: script.capabilities)
        if let major = script.protocolMajor { hello.protocolMajor = major }
        try write(Seemless_V1_Envelope(seq: nextSeq(), replyTo: replyTo, body: .hello(hello)))
    }

    private func receive(_ chunk: Data) {
        guard !finished else { return }
        let out = decoder.decode(chunk)
        for frame in out.frames {
            guard let envelope = try? Seemless_V1_Envelope(serializedBytes: frame.payload) else {
                ended("malformed envelope from host")
                return
            }
            handle(envelope)
        }
        if let error = out.error { ended("framing error from host: \(error)") }
    }

    private func handle(_ envelope: Seemless_V1_Envelope) {
        switch envelope.body {
        case .hello(let hello):
            hostHello = hello
            if envelope.replyTo == 0 { try? sendHello(replyTo: envelope.seq) }
            for w in helloWaiters { w.resume() }
            helloWaiters = []
            log("← hello from \(hello.build)")
            return
        case .ping(let ping):
            guard answerPings else { return }
            var pong = Seemless_V1_Pong()
            pong.nonce = ping.nonce
            try? write(Seemless_V1_Envelope(seq: nextSeq(), replyTo: envelope.seq, body: .pong(pong)))
            return
        case .pong:
            return
        default:
            break
        }
        let name = envelope.bodyName
        received.append(envelope)
        log("← \(name.isEmpty ? "unknown message" : name)")
        wakeExpecters()
        guard envelope.replyTo == 0 else { return }
        answer(envelope, name: name)
    }

    private func answer(_ request: Seemless_V1_Envelope, name: String) {
        if script.ignore.contains(name) { return }
        let body: Seemless_V1_Envelope.OneOf_Body
        if let b = request.body { wm?.observe(b) }
        if let line = helperLine(for: request.body) {
            writeHelper(line)
            log("→ helper: \(line.trimmingCharacters(in: .newlines))")
            body = .ack(Seemless_V1_Ack())
        } else if let json = script.replies[name], let scripted = try? Self.body(json, what: "replies.\(name)") {
            body = scripted
        } else if let b = request.body, let result = wm?.handle(b) {
            try? write(Seemless_V1_Envelope(seq: nextSeq(), replyTo: request.seq, body: result.reply))
            for event in result.events {
                try? write(Seemless_V1_Envelope(seq: nextSeq(), body: event))
                log("→ \(Seemless_V1_Envelope.bodyName(event)) (window manager)")
            }
            return
        } else if name == "getGuestInfo" {
            var info = Seemless_V1_GuestInfo()
            info.osBuild = "mock"
            info.agentVersion = script.build
            if let json = script.guestInfo,
               let text = try? String(decoding: JSONEncoder().encode(json), as: UTF8.self),
               let scripted = try? Seemless_V1_GuestInfo(jsonString: text) {
                info = scripted
            }
            body = .guestInfo(info)
        } else if case .activate(let activate) = request.body {
            body = .activated(.with { $0.id = activate.id })
        } else if Self.queries.contains(name) || name.isEmpty {
            var error = Seemless_V1_Error()
            error.code = .unsupported
            error.message = "the mock agent has no reply for \(name.isEmpty ? "this message" : name)"
            body = .error(error)
        } else {
            body = .ack(Seemless_V1_Ack())
        }
        try? write(Seemless_V1_Envelope(seq: nextSeq(), replyTo: request.seq, body: body))
    }

    // MARK: Guest helper (Zen stand-in, GuestHelperMessage)

    private func helperLine(for body: Seemless_V1_Envelope.OneOf_Body?) -> String? {
        switch body {
        case .setWindowRect(let s) where helper.windows[s.id] != nil:
            return GuestHelperMessage.setLine(id: s.id, rect: s.rect)
        case .windowCommand(let c) where helper.windows[c.id] != nil:
            return GuestHelperMessage.commandLine(id: c.id, c.cmd)
        default:
            return nil
        }
    }

    private func writeHelper(_ line: String) {
        guard helperFD >= 0 else { return }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(helperFD, $0.baseAddress, $0.count) }
    }

    /// Accepts helper connections one after another (it reconnects after a restart).
    private func serveHelper(listener: Int32) async {
        defer { Darwin.close(listener) }
        while !Task.isCancelled {
            guard let fd = try? await Self.accept(listener) else { return }
            helperFD = fd
            log("guest helper connected")
            var pending = Data()
            for await chunk in ByteReader.chunks(fd: fd) {
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    helperReceived(line)
                }
                if pending.count > GuestHelperMessage.maxLineLength { pending.removeAll() }  // no newline: junk
            }
            log("guest helper disconnected")
            Darwin.close(fd)
            helperFD = -1
            // Its windows are gone as far as the host can tell.
            for id in helper.order { helperReceived("gone \(id)") }
        }
    }

    private func helperReceived(_ line: String) {
        guard let message = GuestHelperMessage.parse(line) else {
            if !line.isEmpty { log("helper line ignored: \(line.prefix(80))") }
            return
        }
        guard let body = helper.apply(message) else { return }
        guard hostHello != nil, !finished else { return }   // sent in the snapshot on connect
        try? write(Seemless_V1_Envelope(seq: nextSeq(), body: body))
        log("→ \(Seemless_V1_Envelope.bodyName(body)) (helper)")
    }

    private func waitForHostHello() async {
        if hostHello != nil || finished { return }
        await withCheckedContinuation { helloWaiters.append($0) }
    }

    /// Waits for a host message named `name` that arrived after the previous
    /// `expect` matched (or since connect).
    private var expectCursor = 0

    private func expect(_ name: String, timeout: Duration) async -> Bool {
        if let i = received[expectCursor...].firstIndex(where: { $0.bodyName == name }) {
            expectCursor = i + 1
            return true
        }
        let from = expectCursor
        let found: Bool = await withCheckedContinuation { cont in
            expectWaiters.append((name, from, cont))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireExpect(name)
            }
        }
        return found
    }

    private func wakeExpecters() {
        expectWaiters.removeAll { waiter in
            guard let i = received[waiter.from...].firstIndex(where: { $0.bodyName == waiter.name }) else { return false }
            expectCursor = i + 1
            waiter.cont.resume(returning: true)
            return true
        }
    }

    private func expireExpect(_ name: String) {
        if let i = expectWaiters.firstIndex(where: { $0.name == name }) {
            expectWaiters.remove(at: i).cont.resume(returning: false)
        }
    }

    private func ended(_ reason: String) {
        guard !finished else { return }
        finished = true
        log(reason)
        // The handle (and fd) stays until the next session replaces it, so
        // the reader thread never reads a recycled descriptor.
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        for w in helloWaiters { w.resume() }
        helloWaiters = []
        for w in expectWaiters { w.cont.resume(returning: false) }
        expectWaiters = []
        connectionDone?.resume()
        connectionDone = nil
    }
}
