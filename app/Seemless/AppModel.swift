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
    /// Last screenshot taken here, shown in a preview sheet.
    var screenshot: ScreenshotResult?
    /// VMs currently in Zen mode (docs/05; Z1 preview).
    private(set) var zenSessions: [String: ZenSession] = [:]
    func isInZen(_ name: String) -> Bool { zenSessions[name] != nil }
    /// VMs whose Zen session is connecting (so a second Enter does not start another).
    private var zenStarting: Set<String> = []
    /// Desktop windows (whole guest screen) for VMs with an exported display (WP3.2).
    private var desktopSessions: [String: DesktopSession] = [:]
    private var desktopStarting: Set<String> = []

    struct ScreenshotResult: Identifiable {
        let id = UUID()
        var vm: String
        var file: URL
        var image: NSImage
        var shot: VMScreenshot
    }

    private var pollTask: Task<Void, Never>?
    private var launchSwitchesDone = false
    /// Set by `SEEMLESS_OPEN=select:<vm>`; applied by a later refresh, after
    /// the sidebar list has settled its initial selection.
    private var pendingSelection: String?
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
        // Developer switch for screenshot checks (no UI automation needed):
        // SEEMLESS_OPEN=new-vm opens the New VM sheet at launch.
        showingNewVM = ProcessInfo.processInfo.environment["SEEMLESS_OPEN"]?.hasPrefix("new-vm") == true
        // SEEMLESS_OPEN=select:<vm> starts with that VM selected.
        if let open = ProcessInfo.processInfo.environment["SEEMLESS_OPEN"], open.hasPrefix("select:") {
            let vm = String(open.dropFirst("select:".count))
            pendingSelection = vm
            selection = vm
        }
        if let stack = HostStack.locate(), stack.missingFiles().isEmpty {
            environment = .ready(VMManager(layout: layout, stack: stack))
        } else {
            environment = .stackMissing(HostStack.locate()?.missingFiles() ?? ["build/prefix (run scripts/build-deps.sh all)"])
        }
    }

    /// Developer switches, run once from ContentView (checks without UI automation):
    /// SEEMLESS_OPEN=screenshot:<vm> selects a running VM and takes a screenshot;
    /// SEEMLESS_OPEN=select:<vm> only selects it.
    func runLaunchSwitches() async {
        guard !launchSwitchesDone else { return }
        launchSwitchesDone = true
        guard let open = ProcessInfo.processInfo.environment["SEEMLESS_OPEN"] else { return }
        if open.hasPrefix("select:") { return }  // handled in init and refresh
        if open.hasPrefix("display:") {
            let vm = String(open.dropFirst("display:".count))
            await refresh()
            selection = vm
            showDisplay(vm)
            return
        }
        if open.hasPrefix("zen:") {
            let vm = String(open.dropFirst("zen:".count))
            await refresh()
            selection = vm
            enterZen(vm)
            return
        }
        guard open.hasPrefix("screenshot:") else { return }
        let vm = String(open.dropFirst("screenshot:".count))
        await refresh()
        selection = vm
        takeScreenshot(vm)
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
        if let pending = pendingSelection, items.contains(where: { $0.id == pending }) {
            pendingSelection = nil
            selection = pending
        }
        if pendingSelection == nil {
            if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
            if selection == nil { selection = items.first?.id }
        }
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

    /// `exportDisplay` starts QEMU without its window, exporting the screen
    /// for screenshots (`-display seemless`) until the app has its own
    /// display (WP3.2).
    func start(_ name: String, keys: BootKeys? = nil, paused: Bool = false, exportDisplay: Bool = false) {
        perform(name, "Couldn’t start “\(name)”") { m in
            let display: LaunchOptions.Display = exportDisplay ? .exported : .cocoaWindow
            try await m.start(name, options: LaunchOptions(display: display, bootKeys: keys), resume: !paused)
        }
    }

    /// Saves the VM's screen where macOS saves screenshots and shows it.
    /// Not marked busy: it does not change the VM.
    func takeScreenshot(_ name: String) {
        guard let manager else { return }
        Task {
            do {
                let shot = try await manager.screenshot(name)
                // SEEMLESS_SCREENSHOT_DIR: developer override (checks without touching the Desktop).
                let dir = ProcessInfo.processInfo.environment["SEEMLESS_SCREENSHOT_DIR"]
                    .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? VMScreenshot.defaultDirectory()
                let file = dir.appending(path: VMScreenshot.fileName(vm: name))
                try shot.png.write(to: file)
                guard let image = NSImage(data: shot.png) else { return }
                screenshot = ScreenshotResult(vm: name, file: file, image: image, shot: shot)
            } catch {
                self.error = AppError(title: "Couldn’t take a screenshot of “\(name)”", message: String(describing: error))
            }
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

    // MARK: Zen mode

    /// Shows the VM's Windows windows as chrome-less Mac windows (Z1 preview).
    /// Needs a VM started with an exported display ("Start without Window").
    /// The window list comes from the VM's agent channel, or from the socket
    /// in SEEMLESS_ZEN_AGENT (a `seemlessctl mock-agent`) until the Windows
    /// agent exists (WP4.2). SEEMLESS_ZEN_SCALE sets Mac points per guest pixel.
    func enterZen(_ name: String) {
        guard zenSessions[name] == nil, !zenStarting.contains(name), let manager else { return }
        guard let remote = VMRemote.attach(manager.store.files(for: name)) else {
            error = AppError(title: "Zen mode needs a running VM", message: "Start “\(name)” first.")
            return
        }
        let env = ProcessInfo.processInfo.environment
        let agentSocket = env["SEEMLESS_ZEN_AGENT"].map { URL(filePath: $0) } ?? remote.record.run.agentSocket
        let scale = env["SEEMLESS_ZEN_SCALE"].flatMap(Double.init).map { CGFloat($0) } ?? 1
        // Zen and the desktop window are two views of one screen and share
        // the input monitor: entering Zen closes the desktop window first.
        let desktop = desktopSessions.removeValue(forKey: name)
        desktop?.stop()
        zenStarting.insert(name)
        Task {
            defer { zenStarting.remove(name) }
            await desktop?.closed?.value
            do {
                let session = try await ZenSession.start(vm: name, run: remote.record.run, agentSocket: agentSocket,
                                                         pointsPerPixel: scale)
                // The model lives as long as the app, so a strong capture is fine.
                // Only this session's own end clears the entry: after Exit and
                // a quick re-enter the entry belongs to the new session.
                session.onEnd = { ended, reason in
                    guard self.zenSessions[ended.vm] === ended else { return }
                    self.zenSessions[ended.vm] = nil
                    if let reason { self.error = AppError(title: "Zen mode ended for “\(ended.vm)”", message: reason) }
                }
                // The guest closed its last app window: show the whole desktop
                // (owner, 2026-11-24; docs/05 "Mode transitions"). No alert.
                session.onLastWindowClosed = { ended in
                    guard self.zenSessions[ended.vm] === ended else { return }
                    self.zenSessions[ended.vm] = nil
                    self.showDisplay(ended.vm, after: ended)
                }
                zenSessions[name] = session
            } catch {
                self.error = AppError(title: "Couldn’t enter Zen mode", message: String(describing: error))
            }
        }
    }

    func exitZen(_ name: String) {
        zenSessions.removeValue(forKey: name)?.stop()
    }

    /// Shows the VM's screen. A VM started with an exported display ("Start
    /// without Window") gets the app's own desktop window (opened, or brought
    /// forward); one with QEMU's window has that window brought to the front.
    /// Leaves Zen mode first: the two are views of the same screen.
    /// SEEMLESS_DISPLAY_SCALE sets Mac points per guest pixel (default 1).
    func showDisplay(_ name: String) { showDisplay(name, after: nil) }

    /// `endedZen`: a Zen session that already stopped itself; its input
    /// connection must close before the desktop window opens its own.
    private func showDisplay(_ name: String, after endedZen: ZenSession?) {
        if let session = desktopSessions[name] { session.show(); return }
        guard !desktopStarting.contains(name), let manager else { return }
        guard let remote = VMRemote.attach(manager.store.files(for: name)) else {
            activateQEMUWindow(name)
            return
        }
        let scale = ProcessInfo.processInfo.environment["SEEMLESS_DISPLAY_SCALE"].flatMap(Double.init).map { CGFloat($0) } ?? 1
        desktopStarting.insert(name)
        Task {
            defer { desktopStarting.remove(name) }
            // Zen's input connection must be gone before ours connects.
            let zen = zenSessions.removeValue(forKey: name) ?? endedZen
            zen?.stop()
            await zen?.closed?.value
            do {
                let session = try await DesktopSession.start(vm: name, run: remote.record.run, pointsPerPixel: scale)
                session.onEnd = { ended in
                    guard self.desktopSessions[ended.vm] === ended else { return }
                    self.desktopSessions[ended.vm] = nil
                }
                desktopSessions[name] = session
                session.show()
                if let text = ProcessInfo.processInfo.environment["SEEMLESS_DISPLAY_TYPE"] {
                    try? await Task.sleep(for: .seconds(1))
                    await session.typeForTesting(text.replacingOccurrences(of: "\\n", with: "\n"))
                }
            } catch DisplayError.notExported {
                activateQEMUWindow(name)    // QEMU has its own window
            } catch {
                self.error = AppError(title: "Couldn’t show the display of “\(name)”", message: String(describing: error))
            }
        }
    }

    /// Brings QEMU's own display window (`-display cocoa`) to the front.
    private func activateQEMUWindow(_ name: String) {
        guard let pid = item(name)?.status.qemuPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        // Cooperative activation (macOS 14+): the active app yields first.
        NSApp.yieldActivation(to: app)
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

    // MARK: Open in Seemless

    /// Installers waiting for the person to pick a VM and confirm.
    var launchRequest: LaunchRequest?

    struct LaunchRequest: Identifiable {
        let id = UUID()
        var files: [URL]
        var rejected: [URL]
    }

    func requestLaunch(_ urls: [URL]) {
        let files = urls.filter(GuestLaunch.isSupported)
        let rejected = urls.filter { !GuestLaunch.isSupported($0) }
        if var existing = launchRequest {
            existing.files += files.filter { !existing.files.contains($0) }
            existing.rejected += rejected
            launchRequest = existing
        } else {
            launchRequest = LaunchRequest(files: files, rejected: rejected)
        }
    }

    /// The VM an installer goes to by default: the only running one, else
    /// the selected one, else the first.
    var defaultLaunchTarget: String? {
        let running = items.filter { $0.status.state == .running || $0.status.state == .paused }
        if running.count == 1 { return running[0].id }
        return selection ?? items.first?.id
    }

    /// Starts or resumes the VM if needed, then hot-plugs one launch drive
    /// per installer. Returns an error message, or nil on success.
    func sendInstallers(_ files: [URL], to name: String) async -> String? {
        guard let manager else { return "The host stack is not built." }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            switch await manager.status(of: name).state {
            case .stopped, .crashed:
                try await manager.start(name, options: LaunchOptions(display: .cocoaWindow))
            case .paused:
                try await manager.resume(name)
            case .starting, .stopping:
                return "“\(name)” is busy starting or stopping. Try again in a moment."
            case .running:
                break
            }
            for file in files {
                try await manager.launch(name, installer: file, assets: assets)
            }
            await refresh()
            showDisplay(name)
            return nil
        } catch {
            await refresh()
            return String(describing: error)
        }
    }

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
