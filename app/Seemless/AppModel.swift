import AppKit
import Foundation
import Observation
import SeemlessKit

/// UI state over `VMManager`. Views read from here and call its actions;
/// every decision about VMs is made in SeemlessKit.
@Observable @MainActor
final class AppModel {
    struct Item: Identifiable, Equatable {
        var config: VMConfig
        var status: VMManager.Status
        var id: String { config.name }
    }

    enum Environment {
        case ready(VMManager)
        case stackMissing([String])
    }

    let layout: StorageLayout
    let environment: Environment
    let assets: ImageAssets?
    let host = HostInfo.current

    private(set) var items: [Item] = []
    private(set) var broken: [String] = []
    private(set) var diskInfo: [String: DiskTool.ImageInfo] = [:]
    /// VM names with an action in flight (buttons show progress, disable).
    private(set) var busy: Set<String> = []
    var selection: String?
    var error: AppError?
    var showingNewVM = false
    /// Unattended builds started from this app, by VM name.
    private(set) var builds: [String: BuildProgress] = [:]

    private var pollTask: Task<Void, Never>?
    private var lastDiskRefresh: [String: Date] = [:]

    struct AppError: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// `SEEMLESS_ROOT` points the app at another storage root (experiments,
    /// screenshots), like `seemlessctl --root`.
    init(layout: StorageLayout = AppModel.defaultLayout()) {
        self.layout = layout
        self.assets = ImageAssets.locate()
        if let stack = HostStack.locate(), stack.missingFiles().isEmpty {
            environment = .ready(VMManager(layout: layout, stack: stack))
        } else {
            environment = .stackMissing(HostStack.locate()?.missingFiles() ?? ["build/prefix (run scripts/build-deps.sh all)"])
        }
    }

    nonisolated static func defaultLayout() -> StorageLayout {
        if let root = ProcessInfo.processInfo.environment["SEEMLESS_ROOT"], !root.isEmpty {
            return StorageLayout(root: URL(filePath: root, directoryHint: .isDirectory))
        }
        return .default
    }

    var manager: VMManager? {
        if case .ready(let m) = environment { return m }
        return nil
    }

    var selectedItem: Item? { items.first { $0.id == selection } }

    func item(_ name: String) -> Item? { items.first { $0.id == name } }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil, manager != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() async {
        guard let manager else { return }
        let listed = await manager.list()
        var next: [Item] = []
        for config in listed.configs {
            next.append(Item(config: config, status: await manager.status(of: config.name)))
        }
        if next != items { items = next }
        if listed.broken != broken { broken = listed.broken }
        if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = items.first?.id }
        for item in items where shouldRefreshDisk(item.id) {
            lastDiskRefresh[item.id] = Date()
            if let info = try? await manager.diskInfo(item.id) { diskInfo[item.id] = info }
        }
    }

    private func shouldRefreshDisk(_ name: String) -> Bool {
        guard let last = lastDiskRefresh[name] else { return true }
        let running = item(name)?.status.isActive == true
        return Date().timeIntervalSince(last) > (running ? 10 : 60)
    }

    func refreshDiskSoon(_ name: String) { lastDiskRefresh[name] = nil }

    // MARK: Actions

    /// Runs a VM action, marking the VM busy and turning errors into an alert.
    func perform(_ name: String, _ title: String, _ action: @escaping @Sendable (VMManager) async throws -> Void) {
        guard let manager, !busy.contains(name) else { return }
        busy.insert(name)
        Task {
            defer { busy.remove(name) }
            do {
                try await action(manager)
            } catch {
                self.error = AppError(title: title, message: String(describing: error))
            }
            await refresh()
        }
    }

    func start(_ name: String, keys: BootKeys? = nil, paused: Bool = false) {
        perform(name, "Couldn’t start “\(name)”") { m in
            try await m.start(name, options: LaunchOptions(display: .cocoaWindow, bootKeys: keys), resume: !paused)
        }
    }

    func pause(_ name: String) { perform(name, "Couldn’t pause “\(name)”") { try await $0.pause(name) } }
    func resume(_ name: String) { perform(name, "Couldn’t resume “\(name)”") { try await $0.resume(name) } }
    func restart(_ name: String) { perform(name, "Couldn’t restart “\(name)”") { try await $0.reset(name) } }

    func shutDown(_ name: String, force: Bool = false) {
        perform(name, "Couldn’t shut down “\(name)”") { m in
            _ = try await m.stop(name, graceful: force ? .zero : .seconds(90))
        }
    }

    func save(_ config: VMConfig) async -> Bool {
        guard let manager else { return false }
        do {
            try await manager.update(config)
            refreshDiskSoon(config.name)
            await refresh()
            return true
        } catch {
            self.error = AppError(title: "Couldn’t save settings", message: String(describing: error))
            return false
        }
    }

    func attach(_ name: String, files: [URL]) {
        perform(name, "Couldn’t attach media") { m in
            for file in files { _ = try await m.attachMedia(name, file: file) }
        }
    }

    func detach(_ name: String, path: String) {
        perform(name, "Couldn’t eject media") { m in _ = try await m.detachMedia(name, path: path) }
    }

    func resetFirmware(_ name: String) {
        perform(name, "Couldn’t reset UEFI variables") { try await $0.resetFirmwareVariables(name) }
    }

    func resetTPM(_ name: String) { perform(name, "Couldn’t clear the TPM") { try await $0.resetTPM(name) } }

    func delete(_ name: String) {
        perform(name, "Couldn’t delete “\(name)”") { try await $0.delete(name) }
    }

    func snapshot(_ name: String, _ op: SnapshotOp, label: String) {
        refreshDiskSoon(name)
        perform(name, "Snapshot failed") { m in
            switch op {
            case .create: try await m.createSnapshot(name, label: label)
            case .revert: try await m.revertSnapshot(name, label: label)
            case .delete: try await m.deleteSnapshot(name, label: label)
            }
        }
    }

    enum SnapshotOp { case create, revert, delete }

    /// Brings QEMU's display window to the front (until the app has its own
    /// display path, WP3.2).
    func showDisplay(_ name: String) {
        guard let pid = item(name)?.status.qemuPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    func revealInFinder(_ name: String) {
        guard let manager else { return }
        NSWorkspace.shared.activateFileViewerSelecting([manager.store.files(for: name).directory])
    }

    func openLogs(_ name: String) {
        guard let manager else { return }
        NSWorkspace.shared.open(manager.store.files(for: name).logs)
    }

    func copyWindowsPassword(_ name: String) {
        do {
            guard let password = try WindowsCredentials.load(account: name) else {
                error = AppError(title: "No saved password", message: "Only VMs installed automatically have a Windows password in the Keychain.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
        } catch {
            self.error = AppError(title: "Keychain", message: String(describing: error))
        }
    }

    func hasWindowsPassword(_ name: String) -> Bool { ((try? WindowsCredentials.load(account: name)) ?? nil) != nil }

    // MARK: New VMs

    /// Manual install: blank disk, the ISO attached, Space pressed at the
    /// "boot from CD" prompt on the first start.
    func createManual(_ config: VMConfig, iso: URL?, startNow: Bool) async -> Bool {
        guard let manager else { return false }
        do {
            try await manager.create(config)
            if let iso { _ = try await manager.attachMedia(config.name, file: iso, kind: .cdrom) }
            await refresh()
            selection = config.name
            if startNow { start(config.name, keys: iso == nil ? nil : .cdPrompt) }
            return true
        } catch {
            self.error = AppError(title: "Couldn’t create “\(config.name)”", message: String(describing: error))
            return false
        }
    }

    /// Unattended install (docs/03) in the background; progress in `builds`.
    func createAutomatic(_ request: ImageBuilder.Request) {
        guard let manager, let assets else { return }
        let name = request.vm.name
        let progress = BuildProgress()
        builds[name] = progress
        let builder = ImageBuilder(layout: layout, stack: manager.stack, assets: assets)
        progress.task = Task {
            do {
                let report = try await builder.build(request) { line in
                    Task { @MainActor in progress.append(line) }
                }
                progress.finish(status: report.result.status, directory: report.resultDirectory, timedOut: report.timedOut)
            } catch {
                progress.fail(String(describing: error))
            }
            await refresh()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
            selection = name
        }
    }

    func dismissBuild(_ name: String) { builds[name] = nil }

    // MARK: Quit

    var ownedActiveCount: Int { items.filter { $0.status.owner == .here && $0.status.isActive }.count }

    func shutDownOwned() async {
        await manager?.stopOwned(graceful: .seconds(30))
    }
}

/// Log and outcome of one unattended install.
@Observable @MainActor
final class BuildProgress {
    private(set) var lines: [String] = []
    private(set) var outcome: Outcome = .running
    var task: Task<Void, Never>?

    enum Outcome: Equatable {
        case running
        case finished(status: String?, directory: URL, timedOut: Bool)
        case failed(String)
    }

    func append(_ line: String) { lines.append(line) }
    func finish(status: String?, directory: URL, timedOut: Bool) {
        outcome = .finished(status: status, directory: directory, timedOut: timedOut)
    }
    func fail(_ message: String) { outcome = .failed(message); lines.append("error: \(message)") }

    var succeeded: Bool {
        if case .finished(let status, _, let timedOut) = outcome { return status == "FIRSTBOOT_OK" && !timedOut }
        return false
    }
}
