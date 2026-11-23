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
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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
            Button("Show Display") { model.showDisplay(name) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(item?.status.isActive ?? false))
            Button("Show in Finder") { model.revealInFinder(name) }
                .disabled(item == nil)
        }
    }
}
