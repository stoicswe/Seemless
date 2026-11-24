import Darwin
import Foundation

/// Owns one running VM: the swtpm and QEMU child processes and the QMP
/// connection (docs/02 "Lifecycle").
///
/// ```
/// stopped → starting → running ⇄ paused
///                         └→ stopping → stopped
///               any state → crashed
/// ```
/// Suspend/resume-from-disk is not here yet: it depends on spike S6.
public actor VMProcess {
    public enum State: Sendable, Equatable, CustomStringConvertible {
        case stopped, starting, running, paused, stopping
        case crashed(String)

        public var description: String {
            switch self {
            case .stopped: return "stopped"
            case .starting: return "starting"
            case .running: return "running"
            case .paused: return "paused"
            case .stopping: return "stopping"
            case .crashed(let why): return "crashed (\(why))"
            }
        }
    }

    public enum ProcessError: Error, CustomStringConvertible {
        case stackIncomplete([String]), alreadyRunning(Int32), notRunning, invalidState(State)
        case childFailed(String, String)

        public var description: String {
            switch self {
            case .stackIncomplete(let m): return "host stack incomplete, missing: \(m.joined(separator: ", "))"
            case .alreadyRunning(let pid): return "VM is already running (QEMU pid \(pid))"
            case .notRunning: return "VM is not running"
            case .invalidState(let s): return "not possible while \(s)"
            case .childFailed(let what, let log): return "\(what) failed to start:\n\(log)"
            }
        }
    }

    public let config: VMConfig
    public let stack: HostStack
    public let files: VMFiles
    public let options: LaunchOptions
    public let run: RunPaths

    public private(set) var state: State = .stopped
    public private(set) var qmp: QMPClient?
    public nonisolated let states: AsyncStream<State>
    private let stateSink: AsyncStream<State>.Continuation

    private var qemu: Process?
    private var swtpm: Process?
    private var qemuLogHandle: FileHandle?
    private var stopRequested = false
    /// True once the current QEMU process has exited and cleanup ran.
    private var exited = true
    private var exitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var eventTask: Task<Void, Never>?
    private var bootKeyTask: Task<Void, Never>?

    public init(config: VMConfig, stack: HostStack, files: VMFiles, options: LaunchOptions, runDirectory: URL) {
        self.config = config
        self.stack = stack
        self.files = files
        self.options = options
        self.run = RunPaths(directory: runDirectory)
        (states, stateSink) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(32))
        stateSink.yield(.stopped)
    }

    public var command: QEMUCommand {
        QEMUCommand(config: config, stack: stack, files: files, run: run, options: options)
    }

    public var qemuPID: Int32? { qemu?.processIdentifier }

    // MARK: Start

    /// Starts swtpm and QEMU. With `resume` (default) the vCPUs are released
    /// once QMP is connected; otherwise the VM stays paused in `prelaunch`.
    public func start(resume: Bool = true) async throws {
        guard state == .stopped || isCrashed else { throw ProcessError.invalidState(state) }
        let missing = stack.missingFiles()
        guard missing.isEmpty else { throw ProcessError.stackIncomplete(missing) }
        if let record = RunningVM.read(files), record.isAlive { throw ProcessError.alreadyRunning(record.qemuPID) }

        stopRequested = false
        exited = false
        set(.starting)
        do {
            try prepareRunDirectory()
            if config.boot.tpm { try await startSwtpm() }
            try await startQEMU()
            let client = try await QMPClient.connect(socket: run.qmpSocket, timeout: .seconds(15))
            qmp = client
            watchEvents(client)
            try RunningVM(qemuPID: qemu!.processIdentifier, swtpmPID: swtpm?.processIdentifier ?? 0,
                          runDirectory: run.directory.path(percentEncoded: false), startedAt: Date()).write(files)
            // Offline first setup (owner, 2026-11-24): unplug the cable
            // before the vCPUs run, so Windows never sees a network until
            // its first setup reaches the desktop.
            if config.offlineUntilSetupDone, config.effectiveNetwork != .none {
                try await NetworkLink.set(connected: false, qmp: client, run: run)
            }
            if resume {
                try await client.cont()
                set(.running)
                bootKeyTask = options.bootKeys?.press(on: client)
            } else {
                set(.paused)
            }
        } catch {
            let log = tail(run.qemuLog)
            await hardKill()
            await waitForExit(timeout: .seconds(5))
            cleanUp()
            set(.crashed("start failed"))
            if !log.isEmpty, !(error is ProcessError) { throw ProcessError.childFailed("QEMU", log) }
            throw error
        }
    }

    private var isCrashed: Bool { if case .crashed = state { return true }; return false }

    private func prepareRunDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: run.directory, withIntermediateDirectories: true)
        for socket in run.sockets {
            guard StorageLayout.isValidSocketPath(socket) else {
                throw UnixSocket.Failure.pathTooLong(socket.path(percentEncoded: false))
            }
            try? fm.removeItem(at: socket)
        }
        try fm.createDirectory(at: files.tpmState, withIntermediateDirectories: true)
        try fm.createDirectory(at: files.logs, withIntermediateDirectories: true)
        try fm.createDirectory(at: files.shaderCache, withIntermediateDirectories: true)
    }

    private func startSwtpm() async throws {
        let p = Process()
        p.executableURL = stack.swtpm
        p.arguments = command.swtpmArguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        swtpm = p
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: run.swtpmSocket.path(percentEncoded: false)) {
            guard p.isRunning, ContinuousClock.now < deadline else {
                throw ProcessError.childFailed("swtpm", tail(run.swtpmLog))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func startQEMU() async throws {
        FileManager.default.createFile(atPath: run.qemuLog.path(percentEncoded: false), contents: nil)
        let log = try FileHandle(forWritingTo: run.qemuLog)
        qemuLogHandle = log
        let cmd = command
        let p = Process()
        p.executableURL = stack.qemu
        p.arguments = cmd.arguments
        p.environment = ProcessInfo.processInfo.environment.merging(cmd.environment) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { await self?.qemuExited(status: status, reason: reason) }
        }
        try p.run()
        qemu = p
    }

    private func watchEvents(_ client: QMPClient) {
        eventTask = Task { [weak self] in
            for await event in client.events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: QMPEvent) {
        switch event.name {
        case "STOP": if state == .running { set(.paused) }
        case "RESUME": if state == .paused || state == .starting { set(.running) }
        case "SHUTDOWN": set(.stopping)
        default: break
        }
    }

    // MARK: Control

    public func pause() async throws {
        guard state == .running, let qmp else { throw ProcessError.invalidState(state) }
        try await qmp.stop()
        set(.paused)
    }

    public func resume() async throws {
        guard state == .paused, let qmp else { throw ProcessError.invalidState(state) }
        // Started with resume: false, the vCPUs have not run yet, so this
        // is the moment boot keys are useful.
        let firstRun = (try? await qmp.queryStatus().state) == "prelaunch"
        try await qmp.cont()
        set(.running)
        if firstRun, bootKeyTask == nil { bootKeyTask = options.bootKeys?.press(on: qmp) }
    }

    /// Hard reset, like a PC's reset button: Windows is not asked first.
    public func reset() async throws {
        guard state == .running || state == .paused, let qmp else { throw ProcessError.invalidState(state) }
        try await qmp.systemReset()
        if state == .paused {
            try await qmp.cont()
            set(.running)
        }
    }

    /// Stops the VM. Asks the guest to shut down (ACPI power button) and waits
    /// up to `graceful`; then QMP `quit`; then SIGTERM, then SIGKILL.
    /// Returns how it ended, for logs and tests.
    @discardableResult
    public func stop(graceful: Duration = .seconds(60)) async -> StopMethod {
        guard qemu?.isRunning == true else { return .alreadyStopped }
        stopRequested = true
        set(.stopping)
        if graceful > .zero, state != .paused, let qmp {
            try? await qmp.systemPowerdown()
            if await waitForExit(timeout: graceful) { return .guestShutdown }
        }
        if let qmp {
            await qmp.quit()
            if await waitForExit(timeout: .seconds(5)) { return .quit }
        }
        qemu?.terminate()
        if await waitForExit(timeout: .seconds(5)) { return .terminated }
        await hardKill()
        await waitForExit(timeout: .seconds(5))
        return .killed
    }

    public enum StopMethod: String, Sendable { case alreadyStopped, guestShutdown, quit, terminated, killed }

    private func hardKill() async {
        if let pid = qemu?.processIdentifier, qemu?.isRunning == true { kill(pid, SIGKILL) }
        if let pid = swtpm?.processIdentifier, pid > 0, swtpm?.isRunning == true { kill(pid, SIGKILL) }
    }

    /// Waits until QEMU has exited and cleanup ran. Returns false on timeout.
    ///
    /// One continuation, resumed by whichever comes first: the exit handler
    /// or the timer. (A task group would wait for its uncancellable "exited"
    /// child, so the timeout would never take effect.)
    @discardableResult
    public func waitForExit(timeout: Duration) async -> Bool {
        if exited || qemu == nil { return true }
        let id = UUID()
        return await withCheckedContinuation { cont in
            exitWaiters[id] = cont
            Task {
                try? await Task.sleep(for: timeout)
                self.expireWaiter(id)
            }
        }
    }

    /// Waits until QEMU exits, however long that takes (foreground `vm run`).
    public func waitForExitIndefinitely() async {
        while !(await waitForExit(timeout: .seconds(3600))) {}
    }

    private func expireWaiter(_ id: UUID) {
        exitWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    // MARK: Exit and cleanup

    private func qemuExited(status: Int32, reason: Process.TerminationReason) {
        let expected = stopRequested || state == .stopping
        let log = tail(run.qemuLog)
        archiveLog()
        cleanUp()
        if expected || (status == 0 && reason == .exit) {
            set(.stopped)
        } else {
            let how = reason == .uncaughtSignal ? "signal \(status)" : "exit \(status)"
            set(.crashed(log.isEmpty ? how : "\(how): \(log.split(separator: "\n").last ?? "")"))
        }
        exited = true
        let waiters = exitWaiters.values
        exitWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    private func cleanUp() {
        eventTask?.cancel()
        eventTask = nil
        bootKeyTask?.cancel()
        bootKeyTask = nil
        if let qmp { Task { await qmp.close() } }
        qmp = nil
        // swtpm runs with --terminate and exits when QEMU disconnects; make
        // sure it does not linger if QEMU never connected.
        if let s = swtpm, s.isRunning { s.terminate() }
        try? qemuLogHandle?.close()
        qemuLogHandle = nil
        try? FileManager.default.removeItem(at: files.runningRecord)
        for socket in run.sockets { try? FileManager.default.removeItem(at: socket) }
        // Keep the run directory only if something unexpected is still in it
        // (qemu.log is archived to the VM's logs directory first).
        try? FileManager.default.removeItem(at: run.qemuLog)
        try? FileManager.default.removeItem(at: run.swtpmLog)
        if (try? FileManager.default.contentsOfDirectory(atPath: run.directory.path(percentEncoded: false)))?.isEmpty == true {
            try? FileManager.default.removeItem(at: run.directory)
        }
    }

    /// Keeps the last few QEMU logs in the VM's logs directory (diagnostics, docs/07).
    private func archiveLog() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: run.qemuLog.path(percentEncoded: false)) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = files.logs.appending(path: "qemu-\(stamp).log")
        try? fm.copyItem(at: run.qemuLog, to: dest)
        let logs = (try? fm.contentsOfDirectory(at: files.logs, includingPropertiesForKeys: nil)) ?? []
        let qemuLogs = logs.filter { $0.lastPathComponent.hasPrefix("qemu-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in qemuLogs.dropLast(5) { try? fm.removeItem(at: old) }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        stateSink.yield(new)
    }

    private func tail(_ url: URL, lines: Int = 20) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

// MARK: - Controlling a VM started by another process

/// Controls a VM that some other process (another `seemlessctl`, later the
/// app's helper) started, through its QMP socket.
public struct VMRemote: Sendable {
    public let files: VMFiles
    public let record: RunningVM

    /// Returns nil if the VM is not running.
    public static func attach(_ files: VMFiles) -> VMRemote? {
        guard let record = RunningVM.read(files), record.isAlive else { return nil }
        return VMRemote(files: files, record: record)
    }

    public func connect() async throws -> QMPClient {
        try await QMPClient.connect(socket: record.run.controlSocket, timeout: .seconds(5))
    }

    /// Hard reset (QMP `system_reset`); a paused VM is resumed afterwards.
    public func reset() async throws {
        let qmp = try await connect()
        defer { Task { await qmp.close() } }
        let paused = (try? await qmp.queryStatus().running) == false
        try await qmp.systemReset()
        if paused { try await qmp.cont() }
    }

    /// Same escalation as `VMProcess.stop`, driven from outside the owner.
    public func stop(graceful: Duration = .seconds(60)) async throws -> VMProcess.StopMethod {
        let qmp = try await connect()
        let paused = (try? await qmp.queryStatus().running) == false
        if graceful > .zero, !paused {
            try? await qmp.systemPowerdown()
            if await waitForPIDExit(timeout: graceful) { return .guestShutdown }
        }
        await qmp.quit()
        if await waitForPIDExit(timeout: .seconds(5)) { return .quit }
        kill(record.qemuPID, SIGTERM)
        if await waitForPIDExit(timeout: .seconds(5)) { return .terminated }
        kill(record.qemuPID, SIGKILL)
        _ = await waitForPIDExit(timeout: .seconds(5))
        return .killed
    }

    private func waitForPIDExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if kill(record.qemuPID, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
