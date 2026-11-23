import Foundation

/// An asynchronous QMP event, e.g. `SHUTDOWN`, `STOP`, `RESUME`.
public struct QMPEvent: Sendable, Equatable {
    public var name: String
    public var data: JSONValue
    /// Seconds since the epoch, from QMP's timestamp.
    public var timestamp: Double

    public init(name: String, data: JSONValue = .null, timestamp: Double = 0) {
        self.name = name
        self.data = data
        self.timestamp = timestamp
    }
}

public enum QMPError: Error, Equatable, CustomStringConvertible {
    /// QEMU returned `{"error": {"class": ..., "desc": ...}}`.
    case command(name: String, errorClass: String, description: String)
    case notQMP(String)
    case disconnected
    case timeout(String)

    public var description: String {
        switch self {
        case .command(let name, let cls, let desc): return "QMP \(name) failed: \(cls): \(desc)"
        case .notQMP(let line): return "peer is not speaking QMP: \(line.prefix(200))"
        case .disconnected: return "QMP connection closed"
        case .timeout(let what): return "QMP timed out waiting for \(what)"
        }
    }
}

/// Client for the QEMU Machine Protocol over a unix socket (docs/02 "QMP client").
///
/// Newline-delimited JSON. Requests carry an `id`; replies are matched by it.
/// Events are delivered on `events` in order.
public actor QMPClient {
    private let fd: Int32
    private let handle: FileHandle
    private var nextID = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var greetingWaiter: CheckedContinuation<JSONValue, Error>?
    /// Outcome of the greeting, kept so a waiter that registers late still
    /// sees it (the greeting can arrive, or be rejected, before anyone waits).
    private var greetingResult: Result<JSONValue, Error>?
    private var closed = false
    private var readerTask: Task<Void, Never>?

    /// QEMU version and capabilities from the greeting.
    public private(set) var serverInfo: JSONValue = .null

    public nonisolated let events: AsyncStream<QMPEvent>
    private let eventSink: AsyncStream<QMPEvent>.Continuation

    private init(fd: Int32) {
        self.fd = fd
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        (events, eventSink) = AsyncStream.makeStream(of: QMPEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Connects (retrying until `timeout` while QEMU starts), reads the
    /// greeting and negotiates capabilities.
    public static func connect(socket: URL, timeout: Duration = .seconds(10)) async throws -> QMPClient {
        let fd = try await UnixSocket.connect(path: socket.path(percentEncoded: false), timeout: timeout)
        let client = QMPClient(fd: fd)
        await client.startReading()
        try await client.handshake(timeout: timeout)
        return client
    }

    private func startReading() {
        // Blocking reads run on a dedicated thread, never on the Swift
        // concurrency pool: `FileHandle.bytes` blocks pool threads, and a few
        // idle connections (QMP, agent, bulk) then starve every other task.
        let lines = LineReader.lines(fd: fd)
        readerTask = Task { [weak self] in
            for await line in lines {
                await self?.receive(line)
            }
            await self?.connectionClosed()
        }
    }

    private func handshake(timeout: Duration) async throws {
        let hello = try await withTimeout(timeout, what: "greeting") {
            try await self.waitForGreeting()
        }
        serverInfo = hello["QMP"] ?? .null
        _ = try await execute("qmp_capabilities")
    }

    private func waitForGreeting() async throws -> JSONValue {
        if let result = greetingResult { return try result.get() }
        // Cancellation must resume the continuation, or `withTimeout` (which
        // waits for all its child tasks) would never return.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let result = greetingResult {
                    cont.resume(with: result)
                } else if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    greetingWaiter = cont
                }
            }
        } onCancel: {
            Task { await self.settleGreeting(.failure(CancellationError()), onlyWaiter: true) }
        }
    }

    /// Records the greeting outcome (once) and wakes the waiter, if any.
    /// `onlyWaiter` resumes a waiter without recording a result (cancellation).
    private func settleGreeting(_ result: Result<JSONValue, Error>, onlyWaiter: Bool = false) {
        if !onlyWaiter {
            guard greetingResult == nil else { return }
            greetingResult = result
        }
        greetingWaiter?.resume(with: result)
        greetingWaiter = nil
    }

    /// Runs a QMP command and returns its `return` value.
    @discardableResult
    public func execute(_ command: String, arguments: [String: JSONValue]? = nil) async throws -> JSONValue {
        guard !closed else { throw QMPError.disconnected }
        nextID += 1
        let id = "seemless-\(nextID)"
        var message: [String: JSONValue] = ["execute": .string(command), "id": .string(id)]
        if let arguments { message["arguments"] = .object(arguments) }
        var data = try JSONEncoder().encode(JSONValue.object(message))
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try handle.write(contentsOf: data)
            } catch {
                pending[id] = nil
                cont.resume(throwing: QMPError.disconnected)
            }
        }
    }

    /// Closes the connection. Pending commands fail with `.disconnected`.
    public func close() {
        guard !closed else { return }
        shutdown(fd, SHUT_RDWR)
        connectionClosed()
    }

    // MARK: - Receiving

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              message.objectValue != nil else {
            if greetingResult == nil { settleGreeting(.failure(QMPError.notQMP(line))) }
            return
        }
        if message["QMP"] != nil {
            settleGreeting(.success(message))
        } else if let name = message["event"]?.stringValue {
            let ts = message["timestamp"]
            let seconds = (ts?["seconds"]?.doubleValue ?? 0) + (ts?["microseconds"]?.doubleValue ?? 0) / 1_000_000
            eventSink.yield(QMPEvent(name: name, data: message["data"] ?? .null, timestamp: seconds))
        } else if let id = message["id"]?.stringValue, let cont = pending.removeValue(forKey: id) {
            if let error = message["error"] {
                cont.resume(throwing: QMPError.command(
                    name: id,
                    errorClass: error["class"]?.stringValue ?? "?",
                    description: error["desc"]?.stringValue ?? "?"))
            } else {
                cont.resume(returning: message["return"] ?? .null)
            }
        }
    }

    private func connectionClosed() {
        guard !closed else { return }
        closed = true
        settleGreeting(.failure(QMPError.disconnected))
        for cont in pending.values { cont.resume(throwing: QMPError.disconnected) }
        pending.removeAll()
        eventSink.finish()
    }

    public var isConnected: Bool { !closed }
}

// MARK: - Typed helpers for the commands SeemlessKit uses

public extension QMPClient {
    struct Status: Sendable, Equatable {
        public var running: Bool
        /// QEMU RunState, e.g. "running", "paused", "prelaunch", "shutdown".
        public var state: String
    }

    func queryStatus() async throws -> Status {
        let r = try await execute("query-status")
        return Status(running: r["running"]?.boolValue ?? false, state: r["status"]?.stringValue ?? "unknown")
    }

    func cont() async throws { try await execute("cont") }
    func stop() async throws { try await execute("stop") }
    /// ACPI power button: asks the guest OS to shut down.
    func systemPowerdown() async throws { try await execute("system_powerdown") }
    func systemReset() async throws { try await execute("system_reset") }
    /// Ends QEMU immediately. The connection closes as QEMU exits, so a
    /// missing reply is expected and not an error.
    func quit() async {
        _ = try? await execute("quit")
    }
}

/// Runs `body`, failing with `QMPError.timeout` after `duration`.
func withTimeout<T: Sendable>(_ duration: Duration, what: String,
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw QMPError.timeout(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
