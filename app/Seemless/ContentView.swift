import SeemlessKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.environment {
            case .stackMissing(let missing):
                StackMissingView(missing: missing)
            case .ready where model.showingWelcome:
                WelcomeView()
            case .ready:
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
                } detail: {
                    if let item = model.selectedItem {
                        VMDetailView(name: item.id)
                            .id(item.id)
                    } else {
                        EmptyLibraryView()
                    }
                }
            }
        }
        .sheet(isPresented: $model.showingNewVM) {
            NewVMView()
        }
        .sheet(item: $model.launchRequest) { request in
            OpenInSeemlessView(request: request)
        }
        .sheet(item: $model.screenshot) { result in
            ScreenshotView(result: result)
        }
        .task { await model.runLaunchSwitches() }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: String?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Virtual Machines") {
                ForEach(model.items) { item in
                    SidebarRow(item: item, building: model.builds[item.id] != nil)
                        .tag(item.id)
                        .contextMenu { contextMenu(item) }
                }
            }
            if !model.broken.isEmpty {
                Section("Unreadable") {
                    ForEach(model.broken, id: \.self) { name in
                        Label(name, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button("Show in Finder") { model.revealInFinder(name) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("New Virtual Machine", systemImage: "plus") { model.showingNewVM = true }
                    .help("New Virtual Machine (⌘N)")
            }
        }
        .confirmationDialog(
            "Delete “\(deleting ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let name = deleting { model.delete(name) }
            }
        } message: {
            Text("The disk, firmware settings, TPM and saved Windows password are removed. This can’t be undone.")
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: AppModel.Item) -> some View {
        if item.status.isActive {
            Button("Show Display") { model.showDisplay(item.id) }
            Button("Shut Down") { model.shutDown(item.id) }
            Button("Force Power Off") { model.shutDown(item.id, force: true) }
        } else {
            Button("Start") { model.start(item.id) }
            Button("Start in Firmware Setup") { model.start(item.id, keys: .firmwareSetup) }
        }
        Divider()
        Button("Show in Finder") { model.revealInFinder(item.id) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = item.id }
            .disabled(item.status.isActive)
    }
}

struct SidebarRow: View {
    var item: AppModel.Item
    var building: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Hierarchical, not accent-coloured: an accent icon vanishes on
            // the accent-coloured selection highlight. The dot shows state.
            Image(systemName: "macwindow")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.status.isActive ? .primary : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.config.name).lineLimit(1)
                Text(building ? "Installing Windows" : item.status.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(item.status.state.tint)
                .frame(width: 7, height: 7)
                .opacity(item.status.isActive || item.status.state.crashReason != nil ? 1 : 0)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Empty and setup states

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No Virtual Machine Selected")
                .font(.title2.weight(.semibold))
            Text("Create one from a Windows 11 ARM64 ISO.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Set Up Windows…") { model.showingWelcome = true }
                    .buttonStyle(.glassProminent)
                Button("New Virtual Machine…") { model.showingNewVM = true }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop(tint: .accentColor))
    }
}

struct StackMissingView: View {
    var missing: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Host stack not built", systemImage: "hammer")
                .font(.title2.weight(.semibold))
            Text("Seemless runs VMs with the QEMU build in build/prefix. Build it once from the repository:")
                .foregroundStyle(.secondary)
            Text("scripts/build-deps.sh fetch && scripts/build-deps.sh all")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            Text("Missing: " + missing.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Or set SEEMLESS_PREFIX to another build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop(tint: .orange))
    }
}

/// Soft colour wash behind the content so the glass has something to refract.
struct WindowBackdrop: View {
    var tint: Color

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [tint.opacity(0.18), .clear], center: .topLeading, startRadius: 40, endRadius: 700)
            RadialGradient(colors: [Color.purple.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 40, endRadius: 650)
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: tint)
    }
}
