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
        /// The running VM's virtual network cable: nil when stopped or
        /// without a network (docs/02 "Network link").
        var networkConnected: Bool? = nil
        var id: String { config.name }
    }

    enum Environment {
        case ready(VMManager)
        case stackMissing([String])
    }

    let layout: StorageLayout
    let environment: Environment
    let assets: ImageAssets?
    /// Guest drivers injected by automatic installs (3D display, network,
    /// agent channel). Nil: Windows installs with basic graphics only.
    let drivers: GuestDrivers?
    let host = HostInfo.current
    /// First run (WP3.4): the welcome flow fills the window while it is set.
    /// Set when the library is empty at launch (or SEEMLESS_OPEN=welcome);
    /// cleared when the person goes to the library.
    var showingWelcome = false
    private var welcomeDecided = false

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
        self.drivers = GuestDrivers.locate()
        if ProcessInfo.processInfo.environment["SEEMLESS_OPEN"]?.hasPrefix("welcome") == true {
            showingWelcome = true
            welcomeDecided = true
        }
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
            let status = await manager.status(of: config.name)
            let link = status.isActive ? await manager.isNetworkConnected(config.name) : nil
            next.append(Item(config: config, status: status, networkConnected: link))
        }
        if next != items { items = next }
        if !welcomeDecided {
            welcomeDecided = true
            showingWelcome = next.isEmpty && listed.broken.isEmpty
        }
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

    /// Starts the VM with its screen exported (`-display seemless`) and
    /// opens the app's desktop window (WP3.2). `qemuWindow` uses QEMU's own
    /// Cocoa window instead (troubleshooting).
    func start(_ name: String, keys: BootKeys? = nil, paused: Bool = false, qemuWindow: Bool = false) {
        guard let manager, !busy.contains(name) else { return }
        busy.insert(name)
        Task {
            defer { busy.remove(name) }
            do {
                let display: LaunchOptions.Display = qemuWindow ? .cocoaWindow : .exported
                try await manager.start(name, options: LaunchOptions(display: display, bootKeys: keys), resume: !paused)
            } catch {
                self.error = AppError(title: "Couldn’t start “\(name)”", message: String(describing: error))
                await refresh()
                return
            }
            await refresh()
            if !qemuWindow { showDisplay(name) }
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

    /// Plugs the VM's network cable in or out (Machine menu). Connecting a
    /// VM that is still in its offline first setup also ends that setup, so
    /// it starts online from then on.
    func setNetwork(_ name: String, connected: Bool) {
        let offlineSetup = item(name)?.config.offlineUntilSetupDone == true
        let verb = connected ? "connect" : "disconnect"
        perform(name, "Couldn’t \(verb) “\(name)” \(connected ? "to" : "from") the network") { m in
            if connected, offlineSetup { try await m.finishOfflineSetup(name) }
            else { try await m.setNetworkConnected(name, connected) }
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
        UserDefaults.standard.removeObject(forKey: Self.licenceNoticeKey(name))
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
        if item(name)?.config.allows(.agent) == false, env["SEEMLESS_ZEN_AGENT"] == nil {
            error = AppError(title: "Zen mode needs the guest agent",
                             message: "“\(name)” is quarantined with its guest agent off. Turn it on in Settings ▸ Quarantine, then restart the VM.")
            return
        }
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
        let env = ProcessInfo.processInfo.environment
        let scale = env["SEEMLESS_DISPLAY_SCALE"].flatMap(Double.init).map { CGFloat($0) }
        let files = manager.store.files(for: name)
        desktopStarting.insert(name)
        Task {
            defer { desktopStarting.remove(name) }
            // Zen's input connection must be gone before ours connects.
            let zen = zenSessions.removeValue(forKey: name) ?? endedZen
            zen?.stop()
            await zen?.closed?.value
            do {
                let session = try await DesktopSession.start(vm: name, run: remote.record.run, files: files,
                                                             scaleOverride: scale)
                session.onEnd = { ended in
                    guard self.desktopSessions[ended.vm] === ended else { return }
                    self.desktopSessions[ended.vm] = nil
                }
                session.onNoticeDismissed = { s in
                    UserDefaults.standard.set(true, forKey: Self.licenceNoticeKey(s.vm))
                }
                desktopSessions[name] = session
                if licenceNoticePending(name) { session.showLicenceNotice() }
                session.show()
                await runDisplaySwitches(session, env: env)
            } catch DisplayError.notExported {
                activateQEMUWindow(name)    // QEMU has its own window
            } catch {
                self.error = AppError(title: "Couldn’t show the display of “\(name)”", message: String(describing: error))
            }
        }
    }

    /// Developer switches for checks without UI automation, run once per
    /// window opened: SEEMLESS_DISPLAY_RESIZE=WxH (points), _FULLSCREEN=1,
    /// _KEYS=<GuestKeyCombo>, _TYPE=<script> (see `typeForTesting`).
    private func runDisplaySwitches(_ session: DesktopSession, env: [String: String]) async {
        let delay = env["SEEMLESS_DISPLAY_DELAY"].flatMap(Double.init) ?? 1
        if let size = env["SEEMLESS_DISPLAY_RESIZE"] {
            let p = size.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 {
                try? await Task.sleep(for: .seconds(delay))
                session.resizeForTesting(points: CGSize(width: p[0], height: p[1]))
            }
        }
        if env["SEEMLESS_DISPLAY_FULLSCREEN"] == "1" {
            try? await Task.sleep(for: .seconds(delay))
            session.toggleFullScreen()
        }
        if let combo = env["SEEMLESS_DISPLAY_KEYS"].flatMap(GuestKeyCombo.init(rawValue:)) {
            try? await Task.sleep(for: .seconds(delay))
            session.send(combo)
        }
        if let text = env["SEEMLESS_DISPLAY_TYPE"] {
            try? await Task.sleep(for: .seconds(delay))
            await session.typeForTesting(text.replacingOccurrences(of: "\\n", with: "\n"))
        }
    }

    // MARK: Desktop window menu (Display menu)

    /// The desktop window the Display menu acts on: the key window if it is
    /// one, else the selected VM's.
    var activeDesktop: DesktopSession? {
        if let key = NSApp.keyWindow, let s = desktopSessions.values.first(where: { $0.window === key }) { return s }
        return selection.flatMap { desktopSessions[$0] }
    }

    /// Bumped when display preferences change, so menus redraw their checkmarks.
    private(set) var displayRevision = 0

    func displayPreferences(_ name: String) -> DisplayPreferences {
        _ = displayRevision
        if let s = desktopSessions[name] { return s.preferences }
        guard let manager else { return DisplayPreferences() }
        return DisplayPreferences.load(manager.store.files(for: name))
    }

    func setDisplayPreferences(_ name: String, _ prefs: DisplayPreferences) {
        if let s = desktopSessions[name] {
            s.update(prefs)
        } else if let manager {
            do { try prefs.save(manager.store.files(for: name)) } catch {
                self.error = AppError(title: "Couldn’t save display settings", message: String(describing: error))
            }
        }
        displayRevision += 1
    }

    func send(_ combo: GuestKeyCombo) { activeDesktop?.send(combo) }

    func toggleFullScreen() { activeDesktop?.toggleFullScreen() }

    func hasDesktopWindow(_ name: String) -> Bool { desktopSessions[name] != nil }

    // MARK: Licence notice

    nonisolated static func licenceNoticeKey(_ name: String) -> String { "Seemless.licenceNoticeDone.\(name)" }

    /// The VM was installed here without the licence accepted on the Mac
    /// (always, for installs made by this app), and the person has not yet
    /// dismissed the notice: Windows will show its licence page.
    func licenceNoticePending(_ name: String) -> Bool {
        guard let manager, !UserDefaults.standard.bool(forKey: Self.licenceNoticeKey(name)) else { return false }
        let manifest = manager.store.files(for: name).directory.appending(path: "image-build.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["licenseAcceptedOnHost"] as? Bool == false
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
    /// The guest drivers are injected when found, the screen is exported (no
    /// QEMU window; "Watch" opens it in a desktop window), and Microsoft's
    /// licence is never accepted here: Windows shows it at first start for
    /// the person to accept. `startWhenDone` starts Windows in its desktop
    /// window after a successful install.
    func createAutomatic(_ request: ImageBuilder.Request, startWhenDone: Bool = true) {
        guard let manager, let assets else { return }
        var request = request
        request.acceptWindowsLicense = false
        request.display = .exported
        if request.drivers == nil { request.drivers = drivers?.root }
        let name = request.vm.name
        let progress = BuildProgress()
        progress.hasDrivers = request.drivers != nil
        builds[name] = progress
        let builder = ImageBuilder(layout: layout, stack: manager.stack, assets: assets)
        let disk = manager.store.files(for: name).systemDisk
        progress.task = Task {
            let watch = Task { @MainActor in
                while !Task.isCancelled {
                    let v = try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    progress.diskBytes = Int64(v?.totalFileAllocatedSize ?? 0)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            defer { watch.cancel() }
            do {
                let report = try await builder.build(request, phase: { phase in
                    Task { @MainActor in progress.phase = phase }
                }) { line in
                    Task { @MainActor in progress.append(line) }
                }
                progress.finish(status: report.result.status, directory: report.resultDirectory, timedOut: report.timedOut)
            } catch {
                progress.fail(String(describing: error))
            }
            await refresh()
            if progress.succeeded, startWhenDone { start(name) }
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
                try await manager.start(name, options: LaunchOptions(display: .exported))
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
    var phase: ImageBuilder.Phase?
    let started = Date()
    /// Bytes the system disk takes so far (a sign of life while Windows installs).
    var diskBytes: Int64 = 0
    var hasDrivers = false

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
