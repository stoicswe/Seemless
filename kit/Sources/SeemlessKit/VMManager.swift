import Darwin
import Foundation

/// One place to list, configure and control every VM in a storage root,
/// whether this process started it (`VMProcess`) or another one did
/// (`VMRemote`, e.g. `seemlessctl vm run` or an image build).
///
/// This is what the app's VM manager drives; `seemlessctl` uses the same
/// operations. Settings changes are only allowed while a VM is stopped,
/// because QEMU reads them at launch.
public actor VMManager {
    public nonisolated let layout: StorageLayout
    public nonisolated let stack: HostStack
    public nonisolated var store: VMStore { VMStore(layout: layout, stack: stack) }

    private var owned: [String: VMProcess] = [:]

    public init(layout: StorageLayout, stack: HostStack) {
        self.layout = layout
        self.stack = stack
    }

    // MARK: Status

    public enum Owner: String, Sendable, Equatable {
        /// Started by this process; it ends when this process stops it.
        case here
        /// Started by another process (CLI, image build). Controlled over QMP.
        case elsewhere
    }

    public struct Status: Sendable, Equatable {
        public var state: VMProcess.State
        public var owner: Owner?
        public var qemuPID: Int32?
        public var startedAt: Date?

        public static let stopped = Status(state: .stopped)

        public init(state: VMProcess.State, owner: Owner? = nil, qemuPID: Int32? = nil, startedAt: Date? = nil) {
            self.state = state
            self.owner = owner
            self.qemuPID = qemuPID
            self.startedAt = startedAt
        }

        public var isActive: Bool {
            switch state {
            case .starting, .running, .paused, .stopping: return true
            case .stopped, .crashed: return false
            }
        }
    }

    /// Every VM with a readable config, sorted by name. Unreadable ones are
    /// returned in `broken` so a UI can offer to delete them.
    public func list() -> (configs: [VMConfig], broken: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.vms.path(percentEncoded: false))) ?? []
        var configs: [VMConfig] = []
        var broken: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let s = store
            guard FileManager.default.fileExists(atPath: s.files(for: name).config.path(percentEncoded: false)) else { continue }
            if let config = try? s.load(name) { configs.append(config) } else { broken.append(name) }
        }
        return (configs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, broken)
    }

    public func status(of name: String) async -> Status {
        if let vm = owned[name] {
            let state = await vm.state
            if state != .stopped {
                let record = RunningVM.read(store.files(for: name))
                return Status(state: state, owner: .here, qemuPID: await vm.qemuPID, startedAt: record?.startedAt)
            }
            owned[name] = nil
        }
        guard let remote = VMRemote.attach(store.files(for: name)) else { return .stopped }
        var status = Status(state: .running, owner: .elsewhere, qemuPID: remote.record.qemuPID,
                            startedAt: remote.record.startedAt)
        // The control socket serves one client at a time; if another
        // controller holds it, report "running" rather than failing.
        if let qmp = try? await remote.connect() {
            if let s = try? await qmp.queryStatus() {
                switch s.state {
                case "running": status.state = .running
                case "paused", "prelaunch", "suspended": status.state = .paused
                case "shutdown": status.state = .stopping
                case "internal-error", "guest-panicked": status.state = .crashed(s.state)
                default: status.state = s.running ? .running : .paused
                }
            }
            await qmp.close()
        }
        return status
    }

    // MARK: Lifecycle

    public enum ManagerError: Error, Equatable, CustomStringConvertible {
        case running(String), notRunning(String), cannotShrinkDisk(Int, Int), cannotRename, mediaMissing([String])
        case invalidMedia(String)

        public var description: String {
            switch self {
            case .running(let n): return "VM '\(n)' is running; stop it first"
            case .notRunning(let n): return "VM '\(n)' is not running"
            case .cannotShrinkDisk(let from, let to): return "disks can only grow (\(from) GiB → \(to) GiB requested)"
            case .cannotRename: return "a VM cannot be renamed"
            case .mediaMissing(let paths): return "attached media not found: " + paths.joined(separator: ", ")
            case .invalidMedia(let why): return why
            }
        }
    }

    /// Starts a VM owned by this process.
    public func start(_ name: String, options: LaunchOptions = LaunchOptions(), resume: Bool = true) async throws {
        guard !(await status(of: name)).isActive else { throw ManagerError.running(name) }
        let config = try store.load(name)
        let missing = config.media.filter { !$0.exists }.map(\.path)
        guard missing.isEmpty else { throw ManagerError.mediaMissing(missing) }
        let runDir = layout.runDirectory(pid: getpid()).appending(path: shortID(), directoryHint: .isDirectory)
        let vm = VMProcess(config: config, stack: stack, files: store.files(for: name), options: options, runDirectory: runDir)
        // Kept even if start fails, so status reports the crash reason.
        owned[name] = vm
        try await vm.start(resume: resume)
    }

    public func pause(_ name: String) async throws {
        if let vm = owned[name] { try await vm.pause(); return }
        let qmp = try await remote(name).connect()
        defer { Task { await qmp.close() } }
        try await qmp.stop()
    }

    public func resume(_ name: String) async throws {
        if let vm = owned[name] { try await vm.resume(); return }
        let qmp = try await remote(name).connect()
        defer { Task { await qmp.close() } }
        try await qmp.cont()
    }

    /// Hard reset (reset button). Windows is not asked first.
    public func reset(_ name: String) async throws {
        if let vm = owned[name] { try await vm.reset(); return }
        try await remote(name).reset()
    }

    /// Asks Windows to shut down (ACPI power button), then forces it off
    /// after `graceful`. `.zero` powers off immediately.
    @discardableResult
    public func stop(_ name: String, graceful: Duration = .seconds(60)) async throws -> VMProcess.StopMethod {
        if let vm = owned[name] { return await vm.stop(graceful: graceful) }
        return try await remote(name).stop(graceful: graceful)
    }

    /// Stops every VM this process started (app quit). VMs started
    /// elsewhere keep running.
    public func stopOwned(graceful: Duration = .seconds(30)) async {
        await withTaskGroup(of: Void.self) { group in
            for vm in owned.values { group.addTask { await vm.stop(graceful: graceful) } }
        }
    }

    public var ownedActiveNames: [String] {
        get async {
            var names: [String] = []
            for (name, vm) in owned where await vm.state != .stopped {
                if case .crashed = await vm.state { continue }
                names.append(name)
            }
            return names.sorted()
        }
    }

    private func remote(_ name: String) throws -> VMRemote {
        guard let remote = VMRemote.attach(store.files(for: name)) else { throw ManagerError.notRunning(name) }
        return remote
    }

    private func shortID() -> String { String(UUID().uuidString.prefix(4)).lowercased() }

    // MARK: Create, configure, delete

    @discardableResult
    public func create(_ config: VMConfig, baseImage: URL? = nil) async throws -> VMFiles {
        try await store.create(config, baseImage: baseImage)
    }

    /// Saves a changed config. The VM must be stopped. A bigger
    /// `diskSizeGiB` grows the disk (Windows still has to extend its
    /// partition); a smaller one is refused.
    public func update(_ config: VMConfig) async throws {
        let errors = config.validationErrors()
        guard errors.isEmpty else { throw VMStore.StoreError.invalidConfig(errors) }
        try await requireStopped(config.name)
        let current = try store.load(config.name)
        if config.diskSizeGiB < current.diskSizeGiB {
            throw ManagerError.cannotShrinkDisk(current.diskSizeGiB, config.diskSizeGiB)
        }
        if config.diskSizeGiB > current.diskSizeGiB {
            try await DiskTool(stack: stack).resize(store.files(for: config.name).systemDisk, toGiB: config.diskSizeGiB)
        }
        try store.save(config)
    }

    /// Attaches a file as a USB drive from the next start on.
    public func attachMedia(_ name: String, file: URL, kind: VMConfig.AttachedMedia.Kind? = nil) async throws -> VMConfig {
        try await requireStopped(name)
        var config = try store.load(name)
        let path = file.standardizedFileURL.path(percentEncoded: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw ManagerError.invalidMedia("not a file: \(path)")
        }
        guard !config.media.contains(where: { $0.path == path }) else { return config }
        let kind = kind ?? (file.pathExtension.lowercased() == "iso" ? .cdrom : .disk)
        config.media.append(.init(path: path, kind: kind))
        try store.save(config)
        return config
    }

    public func detachMedia(_ name: String, path: String) async throws -> VMConfig {
        try await requireStopped(name)
        var config = try store.load(name)
        config.media.removeAll { $0.path == path }
        try store.save(config)
        return config
    }

    /// Replaces the UEFI variable store with a blank one: boot entries and
    /// firmware settings are lost, Windows itself is not touched (it
    /// recreates its boot entry from the disk's fallback loader).
    public func resetFirmwareVariables(_ name: String) async throws {
        try await requireStopped(name)
        let url = store.files(for: name).efiVars
        try? FileManager.default.removeItem(at: url)
        try DiskTool.createEFIVars(at: url)
    }

    /// Clears the TPM. Anything sealed to it (BitLocker keys, Windows Hello
    /// PINs) is lost.
    public func resetTPM(_ name: String) async throws {
        try await requireStopped(name)
        let dir = store.files(for: name).tpmState
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func delete(_ name: String) async throws {
        try await requireStopped(name)
        owned[name] = nil
        try store.delete(name)
    }

    public func diskInfo(_ name: String) async throws -> DiskTool.ImageInfo {
        try await DiskTool(stack: stack).info(store.files(for: name).systemDisk)
    }

    // MARK: Snapshots (internal qcow2 snapshots; VM must be stopped)

    public func createSnapshot(_ name: String, label: String) async throws {
        try await requireStopped(name)
        try await DiskTool(stack: stack).createSnapshot(store.files(for: name).systemDisk, name: label)
    }

    public func revertSnapshot(_ name: String, label: String) async throws {
        try await requireStopped(name)
        try await DiskTool(stack: stack).applySnapshot(store.files(for: name).systemDisk, name: label)
    }

    public func deleteSnapshot(_ name: String, label: String) async throws {
        try await requireStopped(name)
        try await DiskTool(stack: stack).deleteSnapshot(store.files(for: name).systemDisk, name: label)
    }

    private func requireStopped(_ name: String) async throws {
        guard store.exists(name) else { throw VMStore.StoreError.notFound(name) }
        if await status(of: name).isActive { throw ManagerError.running(name) }
    }
}
