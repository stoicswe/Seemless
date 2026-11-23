import Foundation

/// Creates, loads and deletes VMs under `StorageLayout.vms`.
public struct VMStore: Sendable {
    public var layout: StorageLayout
    public var stack: HostStack

    public init(layout: StorageLayout, stack: HostStack) {
        self.layout = layout
        self.stack = stack
    }

    public func files(for name: String) -> VMFiles { VMFiles(directory: layout.vm(named: name)) }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: files(for: name).config.path(percentEncoded: false))
    }

    /// Creates a VM directory with config, firmware vars, TPM state directory
    /// and a system disk: an overlay on `baseImage` if given, else a blank disk
    /// (for installing Windows, docs/03).
    @discardableResult
    public func create(_ config: VMConfig, baseImage: URL? = nil) async throws -> VMFiles {
        let errors = config.validationErrors()
        guard errors.isEmpty else { throw StoreError.invalidConfig(errors) }
        guard !exists(config.name) else { throw StoreError.alreadyExists(config.name) }
        let f = files(for: config.name)
        let fm = FileManager.default
        try fm.createDirectory(at: f.directory, withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: f.tpmState, withIntermediateDirectories: true)
            try fm.createDirectory(at: f.logs, withIntermediateDirectories: true)
            try DiskTool.createEFIVars(at: f.efiVars)
            let disks = DiskTool(stack: stack)
            if let baseImage {
                try await disks.createOverlay(at: f.systemDisk, base: baseImage)
            } else {
                try await disks.createDisk(at: f.systemDisk, sizeGiB: config.diskSizeGiB)
            }
            try save(config)
        } catch {
            try? fm.removeItem(at: f.directory)
            throw error
        }
        return f
    }

    public func load(_ name: String) throws -> VMConfig {
        let url = files(for: name).config
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw StoreError.notFound(name)
        }
        return try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: url))
    }

    public func save(_ config: VMConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: files(for: config.name).config, options: .atomic)
    }

    /// Deletes a stopped VM's directory (disk, firmware vars, TPM state).
    public func delete(_ name: String) throws {
        guard exists(name) else { throw StoreError.notFound(name) }
        if let running = RunningVM.read(files(for: name)), running.isAlive {
            throw StoreError.running(name)
        }
        try FileManager.default.removeItem(at: files(for: name).directory)
        WindowsCredentials.delete(account: name)
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case invalidConfig([String]), alreadyExists(String), notFound(String), running(String)
        public var description: String {
            switch self {
            case .invalidConfig(let e): return "invalid config: " + e.joined(separator: "; ")
            case .alreadyExists(let n): return "VM '\(n)' already exists"
            case .notFound(let n): return "no VM named '\(n)'"
            case .running(let n): return "VM '\(n)' is running; stop it first"
            }
        }
    }
}

/// Written next to a VM while its QEMU process runs, so other `seemlessctl`
/// invocations can find the QMP socket (docs/02 lifecycle).
public struct RunningVM: Codable, Sendable, Equatable {
    public var qemuPID: Int32
    public var swtpmPID: Int32
    public var runDirectory: String
    public var startedAt: Date

    public var run: RunPaths { RunPaths(directory: URL(filePath: runDirectory, directoryHint: .isDirectory)) }

    /// True if the QEMU process still exists.
    public var isAlive: Bool { kill(qemuPID, 0) == 0 || errno == EPERM }

    public static func read(_ files: VMFiles) -> RunningVM? {
        guard let data = try? Data(contentsOf: files.runningRecord) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunningVM.self, from: data)
    }

    func write(_ files: VMFiles) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: files.runningRecord, options: .atomic)
    }
}
