import Darwin
import Foundation

public enum AgentError: Error, Equatable, CustomStringConvertible {
    case disconnected(String)
    case timeout(String)
    /// The guest answered with `Error`.
    case remote(Seemless_V1_Error.Code, String)
    /// The guest's agent restarted (sent a fresh Hello) before replying.
    case peerRestarted
    case unexpectedReply(expected: String, got: String)

    public var description: String {
        switch self {
        case .disconnected(let why): return "agent connection closed: \(why)"
        case .timeout(let what): return "agent did not answer \(what) in time"
        case .remote(let code, let message): return "agent error \(code): \(message)"
        case .peerRestarted: return "the guest agent restarted"
        case .unexpectedReply(let e, let g): return "expected \(e) from the agent, got \(g.isEmpty ? "an unknown message" : g)"
        }
    }
}

/// Host side of the agent control channel (docs/06 "Host side").
///
/// Owns one control socket (QEMU's `agent.sock` chardev, or the mock agent),
/// does framing, the Hello exchange, request/response correlation with
/// timeouts, and the 1 s heartbeat. Everything the guest sends is validated
/// before it is surfaced: a framing or decoding error closes the channel,
/// and a bad Hello is rejected.
///
/// Hello rule (both sides): send Hello on connect with `reply_to = 0`;
/// answer every Hello that has `reply_to = 0` with a Hello whose `reply_to`
/// is its seq. virtio-serial drops bytes written while the guest has the
/// port closed, so this guarantees each side sees the other's Hello. A Hello
/// arriving after the session is up means the agent restarted: pending
/// requests fail with `.peerRestarted` and `.peerRestarted` is published, so
/// owners discard guest state (the agent follows with a full snapshot).
public actor AgentClient {
    public enum State: Sendable, Equatable {
        case ready(AgentHandshake.Negotiated)
        /// No Pong for `missedPings` intervals (docs/05 "agent lost").
        case unresponsive
        /// Pongs are arriving again after `.unresponsive`.
        case responsive
        case peerRestarted(AgentHandshake.Negotiated)
        case closed(String)
    }

    public struct Options: Sendable {
        public var build: String
        public var capabilities: [String]
        public var helloTimeout: Duration
        public var requestTimeout: Duration
        public var heartbeatInterval: Duration
        public var missedPings: Int

        public init(build: String = "seemless-host \(Seemless.version)",
                    capabilities: [String] = [AgentHandshake.Capability.core],
                    helloTimeout: Duration = .seconds(10),
                    requestTimeout: Duration = .seconds(5),
                    heartbeatInterval: Duration = .seconds(1),
                    missedPings: Int = 3) {
            self.build = build
            self.capabilities = capabilities
            self.helloTimeout = helloTimeout
            self.requestTimeout = requestTimeout
            self.heartbeatInterval = heartbeatInterval
            self.missedPings = missedPings
        }
    }

    private let fd: Int32
    private let handle: FileHandle
    private let options: Options
    private let localHello: Seemless_V1_Hello
    private var decoder = AgentFrame.Decoder(channel: .control)
    private var nextSeq: UInt64 = 0
    private var pending: [UInt64: CheckedContinuation<Seemless_V1_Envelope, Error>] = [:]
    private var helloWaiter: CheckedContinuation<AgentHandshake.Negotiated, Error>?
    private var helloResult: Result<AgentHandshake.Negotiated, Error>?
    private var closedReason: String?
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var outstandingPing: UInt64?
    private var missed = 0
    private var unresponsive = false

    /// What both sides agreed on; updated when the agent restarts.
    public private(set) var negotiated: AgentHandshake.Negotiated?

    /// Guest events and guest-initiated requests (everything except Hello,
    /// Ping, Pong and replies to our requests), in arrival order.
    public nonisolated let events: AsyncStream<Seemless_V1_Envelope>
    private let eventSink: AsyncStream<Seemless_V1_Envelope>.Continuation
    public nonisolated let states: AsyncStream<State>
    private let stateSink: AsyncStream<State>.Continuation

    private init(fd: Int32, options: Options) {
        self.fd = fd
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.options = options
        self.localHello = AgentHandshake.hello(role: .host, build: options.build, capabilities: options.capabilities)
        (events, eventSink) = AsyncStream.makeStream(of: Seemless_V1_Envelope.self, bufferingPolicy: .bufferingNewest(4096))
        (states, stateSink) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(64))
    }

    /// Connects (retrying while the socket appears), exchanges Hello and
    /// starts the heartbeat. Fails if no valid Hello arrives in time.
    public static func connect(socket: URL, options: Options = Options(),
                               connectTimeout: Duration = .seconds(10)) async throws -> AgentClient {
        let fd = try await UnixSocket.connect(path: socket.path(percentEncoded: false), timeout: connectTimeout)
        let client = AgentClient(fd: fd, options: options)
        do {
            try await client.start()
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    private func start() async throws {
        let chunks = ByteReader.chunks(fd: fd)
        readerTask = Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
            await self?.shut("connection closed by the peer")
        }
        try sendHello(replyTo: 0)
        do {
            _ = try await withTimeout(options.helloTimeout, what: "Hello") { try await self.waitForHello() }
        } catch QMPError.timeout {
            throw AgentError.timeout("Hello (is the guest agent running?)")
        }
        startHeartbeat()
    }

    public var isConnected: Bool { closedReason == nil }

    // MARK: Sending

    private func takeSeq() -> UInt64 {
        nextSeq += 1
        return nextSeq
    }

    private func write(_ envelope: Seemless_V1_Envelope) throws {
        if let closedReason { throw AgentError.disconnected(closedReason) }
        let frame = try AgentFrame.encode(envelope)
        do {
            try handle.write(contentsOf: frame)
        } catch {
            shut("write failed: \(error)")
            throw AgentError.disconnected("write failed")
        }
    }

    private func sendHello(replyTo: UInt64) throws {
        try write(Seemless_V1_Envelope(seq: takeSeq(), replyTo: replyTo, body: .hello(localHello)))
    }

    /// Sends an event (no reply expected).
    public func send(_ body: Seemless_V1_Envelope.OneOf_Body) throws {
        try write(Seemless_V1_Envelope(seq: takeSeq(), body: body))
    }

    /// Answers a guest-initiated request from `events`.
    public func reply(to request: Seemless_V1_Envelope, with body: Seemless_V1_Envelope.OneOf_Body) throws {
        try write(Seemless_V1_Envelope(seq: takeSeq(), replyTo: request.seq, body: body))
    }

    /// Sends a request and waits for its reply. A guest `Error` reply throws
    /// `AgentError.remote`.
    public func request(_ body: Seemless_V1_Envelope.OneOf_Body, timeout: Duration? = nil) async throws -> Seemless_V1_Envelope {
        let seq = takeSeq()
        let envelope = Seemless_V1_Envelope(seq: seq, body: body)
        let name = envelope.bodyName
        let limit = timeout ?? options.requestTimeout
        let reply: Seemless_V1_Envelope = try await withCheckedThrowingContinuation { cont in
            pending[seq] = cont
            do {
                try write(envelope)
            } catch {
                pending[seq] = nil
                cont.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.fail(seq, AgentError.timeout(name))
            }
        }
        if case .error(let e) = reply.body { throw AgentError.remote(e.code, String(e.message.prefix(1024))) }
        return reply
    }

    private func fail(_ seq: UInt64, _ error: Error) {
        pending.removeValue(forKey: seq)?.resume(throwing: error)
    }

    public func guestInfo() async throws -> Seemless_V1_GuestInfo {
        let reply = try await request(.getGuestInfo(Seemless_V1_GetGuestInfo()))
        guard case .guestInfo(let info) = reply.body else {
            throw AgentError.unexpectedReply(expected: "guestInfo", got: reply.bodyName)
        }
        return info
    }

    public func close() {
        shut("closed by the host")
    }

    // MARK: Receiving

    private func receive(_ chunk: Data) {
        guard closedReason == nil else { return }
        let out = decoder.decode(chunk)
        // Frames that arrived before a bad one are still the peer's real messages.
        for frame in out.frames {
            guard let envelope = try? Seemless_V1_Envelope(serializedBytes: frame.payload) else {
                shut("malformed envelope (\(frame.payload.count) bytes)")
                return
            }
            handle(envelope)
            if closedReason != nil { return }
        }
        if let error = out.error { shut("framing error: \(error)") }
    }

    private func handle(_ envelope: Seemless_V1_Envelope) {
        switch envelope.body {
        case .hello(let hello):
            receiveHello(hello, envelope: envelope)
            return
        case .ping(let ping):
            var pong = Seemless_V1_Pong()
            pong.nonce = ping.nonce
            try? write(Seemless_V1_Envelope(seq: takeSeq(), replyTo: envelope.seq, body: .pong(pong)))
            return
        case .pong(let pong):
            if pong.nonce == outstandingPing {
                outstandingPing = nil
                missed = 0
                if unresponsive {
                    unresponsive = false
                    stateSink.yield(.responsive)
                }
            }
            return
        default:
            break
        }
        guard negotiated != nil else { return }  // nothing counts before Hello
        if envelope.replyTo != 0 {
            // A reply to something we did not ask (or that timed out) is dropped.
            pending.removeValue(forKey: envelope.replyTo)?.resume(returning: envelope)
            return
        }
        // Bodies from a newer protocol minor decode as nil: ignored.
        guard envelope.body != nil else { return }
        eventSink.yield(envelope)
    }

    private func receiveHello(_ hello: Seemless_V1_Hello, envelope: Seemless_V1_Envelope) {
        let result: AgentHandshake.Negotiated
        do {
            result = try AgentHandshake.negotiate(local: localHello, remote: hello)
        } catch {
            if helloResult == nil { settleHello(.failure(error)) }
            shut("\(error)")
            return
        }
        if envelope.replyTo == 0 { try? sendHello(replyTo: envelope.seq) }
        // The Hello that answers our own carries no news.
        let restarted = negotiated != nil && envelope.replyTo == 0
        negotiated = result
        if helloResult == nil {
            settleHello(.success(result))
            stateSink.yield(.ready(result))
        } else if restarted {
            for cont in pending.values { cont.resume(throwing: AgentError.peerRestarted) }
            pending.removeAll()
            outstandingPing = nil
            missed = 0
            stateSink.yield(.peerRestarted(result))
        }
    }

    private func waitForHello() async throws -> AgentHandshake.Negotiated {
        if let helloResult { return try helloResult.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let helloResult {
                    cont.resume(with: helloResult)
                } else if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    helloWaiter = cont
                }
            }
        } onCancel: {
            Task { await self.cancelHelloWait() }
        }
    }

    private func cancelHelloWait() {
        helloWaiter?.resume(throwing: CancellationError())
        helloWaiter = nil
    }

    private func settleHello(_ result: Result<AgentHandshake.Negotiated, Error>) {
        guard helloResult == nil else { return }
        helloResult = result
        helloWaiter?.resume(with: result)
        helloWaiter = nil
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        let interval = options.heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.beat() else { return }
            }
        }
    }

    /// One heartbeat tick. Returns false once the connection is closed.
    private func beat() -> Bool {
        guard closedReason == nil else { return false }
        if outstandingPing != nil {
            missed += 1
            if missed >= options.missedPings && !unresponsive {
                unresponsive = true
                stateSink.yield(.unresponsive)
            }
        }
        let nonce = UInt64.random(in: 1...UInt64.max)
        outstandingPing = nonce
        var ping = Seemless_V1_Ping()
        ping.nonce = nonce
        try? send(.ping(ping))
        return closedReason == nil
    }

    // MARK: Closing

    private func shut(_ reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason
        Darwin.shutdown(fd, SHUT_RDWR)
        heartbeatTask?.cancel()
        settleHello(.failure(AgentError.disconnected(reason)))
        for cont in pending.values { cont.resume(throwing: AgentError.disconnected(reason)) }
        pending.removeAll()
        stateSink.yield(.closed(reason))
        stateSink.finish()
        eventSink.finish()
    }
}
