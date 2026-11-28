import AppKit
import SeemlessKit
import SwiftUI

@main
struct SeemlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Seemless", id: "library") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
                // No opaque window fill: each view's WindowBackdrop frosts the wallpaper.
                .containerBackground(.clear, for: .window)
                .onAppear {
                    delegate.model = model
                    model.startPolling()
                }
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands { VMCommands(model: model) }
    }
}

/// Asks before quitting while VMs this app started are running, then shuts
/// them down (QEMU children would otherwise outlive the app).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened before the window (and model) exist are kept until then.
    @MainActor var model: AppModel? {
        didSet { flushPending() }
    }
    @MainActor private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSApp.activate()
    }

    /// Finder "Open With > Seemless" on .exe/.msi files.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    /// Finder Services > "Open in Seemless" (NSServices in Info.plist).
    @MainActor @objc
    func openInSeemless(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        receive(urls)
        NSApp.activate()
    }

    @MainActor private func receive(_ urls: [URL]) {
        pending += urls.filter(\.isFileURL)
        flushPending()
    }

    @MainActor private func flushPending() {
        guard let model, !pending.isEmpty else { return }
        model.requestLaunch(pending)
        pending = []
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.ownedActiveCount > 0 else { return .terminateNow }
        let count = model.ownedActiveCount
        let alert = NSAlert()
        alert.messageText = count == 1 ? "A virtual machine is running" : "\(count) virtual machines are running"
        alert.informativeText = "Seemless will ask Windows to shut down and force it off after 30 seconds. Unsaved work in Windows may be lost."
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.shutDownOwned()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Menu bar commands for the selected VM.
struct VMCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") { model.showingNewVM = true }
                .keyboardShortcut("n")
                .disabled(model.manager == nil)
        }
        CommandMenu("Machine") {
            let item = model.selectedItem
            let state = item?.status.state ?? .stopped
            let name = item?.id ?? ""
            let idle = item != nil && !(item!.status.isActive)
            Button("Start") { model.start(name) }
                .keyboardShortcut("r")
                .disabled(!idle)
            Button("Start in Firmware Setup") { model.start(name, keys: .firmwareSetup) }
                .disabled(!idle)
            Button("Start from Installer Media") { model.start(name, keys: .cdPrompt) }
                .disabled(!idle || item?.config.media.isEmpty != false)
            Button("Start in QEMU Window") { model.start(name, qemuWindow: true) }
                .disabled(!idle)
            Divider()
            Button(state == .paused ? "Resume" : "Pause") {
                state == .paused ? model.resume(name) : model.pause(name)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(state != .running && state != .paused)
            Button("Restart") { model.restart(name) }
                .disabled(state != .running && state != .paused)
            Button("Shut Down") { model.shutDown(name) }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(state != .running)
            Button("Force Power Off") { model.shutDown(name, force: true) }
                .disabled(!(item?.status.isActive ?? false))
            Divider()
            // Unplugs or plugs in the virtual network cable (owner, 2026-11-24).
            Button(item?.networkConnected == false ? "Connect to Network" : "Disconnect from Network") {
                model.setNetwork(name, connected: item?.networkConnected == false)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(item?.networkConnected == nil || model.busy.contains(name))
            Divider()
            Button(model.isInZen(name) ? "Exit Zen Mode" : "Enter Zen Mode (Preview)") {
                model.isInZen(name) ? model.exitZen(name) : model.enterZen(name)
            }
            .keyboardShortcut("z", modifiers: [.command, .control])
            // Zen needs the guest agent's window list; quarantine may leave it out.
            .disabled(!(item?.status.isActive ?? false) || item?.config.allows(.agent) == false
                      || item?.config.hasWacOS == true)
            Button("Show Display") { model.showDisplay(name) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(item?.status.isActive ?? false))
            Button("Take Screenshot") { model.takeScreenshot(name) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!(item?.status.isActive ?? false))
            Button("Show in Finder") { model.revealInFinder(name) }
                .disabled(item == nil)
        }
        CommandMenu("Display") { DisplayMenu(model: model) }
    }
}

/// The desktop window's menu (WP3.2): keys a Mac keyboard cannot send,
/// full screen, scaling and keyboard style for the active VM's window.
struct DisplayMenu: View {
    var model: AppModel

    var body: some View {
        let session = model.activeDesktop
        let name = session?.vm ?? model.selection
        Menu("Send Keys") {
            ForEach(GuestKeyCombo.allCases, id: \.self) { combo in
                Button(combo.title) { model.send(combo) }
            }
        }
        .disabled(session == nil)
        Button(session?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
            .disabled(session == nil)
        Divider()
        if let name {
            let prefs = model.displayPreferences(name)
            Picker("Scaling", selection: Binding(get: { prefs.scaling }, set: { v in
                var p = prefs; p.scaling = v; model.setDisplayPreferences(name, p)
            })) {
                ForEach(DisplayScaling.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Keyboard", selection: Binding(get: { prefs.keyboard }, set: { v in
                var p = prefs; p.keyboard = v; model.setDisplayPreferences(name, p)
            })) {
                ForEach(KeyboardStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Resize Windows with the Window", isOn: Binding(get: { prefs.resizeGuest }, set: { v in
                var p = prefs; p.resizeGuest = v; model.setDisplayPreferences(name, p)
            }))
        }
    }
}
