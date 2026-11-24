import SeemlessKit
import SwiftUI

struct VMDetailView: View {
    @Environment(AppModel.self) private var model
    var name: String
    @State private var editing = false

    var body: some View {
        if let item = model.item(name) {
            content(item)
        }
    }

    private func content(_ item: AppModel.Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(item: item)
                if let build = model.builds[name] {
                    BuildSection(name: name, progress: build)
                }
                HStack(alignment: .top, spacing: 18) {
                    HardwareSection(item: item) { editing = true }
                    BootSection(item: item) { editing = true }
                }
                .fixedSize(horizontal: false, vertical: true)
                MediaSection(item: item)
                SnapshotSection(item: item)
                FilesSection(item: item)
            }
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(WindowBackdrop(tint: item.status.state == .stopped ? .accentColor : item.status.state.tint))
        .navigationTitle(item.config.name)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "slider.horizontal.3") { editing = true }
                    .help(item.status.isActive ? "Settings (read-only while running)" : "Edit settings")
            }
        }
        .sheet(isPresented: $editing) {
            VMSettingsView(original: item.config, locked: item.status.isActive)
        }
    }
}

// MARK: - Header and controls

private struct HeaderView: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Line 1: name and controls. The controls keep their natural
            // size; the name truncates first.
            HStack(alignment: .center, spacing: 16) {
                Text(item.config.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                Spacer(minLength: 12)
                ControlCluster(item: item)
                    .fixedSize()
                    .layoutPriority(1)
            }
            // Line 2: state and provenance, on one baseline.
            HStack(spacing: 8) {
                StatusBadge(state: item.status.state)
                if item.config.isQuarantined {
                    QuarantineBadge()
                        .help("Quarantined: only the connections switched on in Settings reach your Mac.")
                }
                if let since = item.status.startedAt, item.status.isActive {
                    Text("since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if item.status.owner == .elsewhere {
                    Label("Started from Terminal", systemImage: "terminal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                        .help("Started by seemlessctl or an install. Seemless controls it over QEMU's control socket.")
                }
                Spacer(minLength: 0)
            }
            if let why = item.status.state.crashReason {
                Text(why)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.bottom, 4)
    }
}

/// The primary controls. One glass container, so the buttons merge and
/// morph as the VM changes state.
private struct ControlCluster: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item
    @Namespace private var glass

    private var name: String { item.id }
    private var busy: Bool { model.busy.contains(name) }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                switch item.status.state {
                case .stopped, .crashed:
                    Button { model.start(name) } label: {
                        Label("Start", systemImage: "play.fill").frame(minWidth: 70)
                    }
                    .buttonStyle(.glassProminent)
                    .glassEffectID("primary", in: glass)
                    .keyboardShortcut(.defaultAction)
                    Menu {
                        Button("Start in Firmware Setup", systemImage: "cpu") { model.start(name, keys: .firmwareSetup) }
                        Button("Start from Installer Media", systemImage: "opticaldisc") { model.start(name, keys: .cdPrompt) }
                            .disabled(item.config.media.isEmpty)
                        Button("Start Paused", systemImage: "pause") { model.start(name, paused: true) }
                        Divider()
                        Button("Start in QEMU Window", systemImage: "macwindow") { model.start(name, qemuWindow: true) }
                            .help("QEMU's own window instead of the Seemless window (troubleshooting)")
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .glassEffectID("options", in: glass)
                    .help("Start options")
                case .starting, .stopping:
                    ProgressView().controlSize(.small)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("primary", in: glass)
                    Button("Force Off", systemImage: "power") { model.shutDown(name, force: true) }
                        .buttonStyle(.glass)
                        .glassEffectID("options", in: glass)
                case .running, .paused:
                    Button { model.showDisplay(name) } label: {
                        Label("Show Display", systemImage: "display")
                    }
                    .buttonStyle(.glassProminent)
                    .glassEffectID("primary", in: glass)
                    .disabled(item.status.owner == nil)
                    Button {
                        item.status.state == .paused ? model.resume(name) : model.pause(name)
                    } label: {
                        Image(systemName: item.status.state == .paused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("pause", in: glass)
                    .help(item.status.state == .paused ? "Resume" : "Pause")
                    Button { model.takeScreenshot(name) } label: {
                        Image(systemName: "camera")
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("screenshot", in: glass)
                    .help("Take Screenshot")
                    Menu {
                        Button("Shut Down", systemImage: "power") { model.shutDown(name) }
                            .disabled(item.status.state == .paused)
                        Button("Restart", systemImage: "arrow.clockwise") { model.restart(name) }
                        Divider()
                        Button("Force Power Off", systemImage: "bolt.slash", role: .destructive) {
                            model.shutDown(name, force: true)
                        }
                    } label: {
                        Image(systemName: "power")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .glassEffectID("options", in: glass)
                    .help("Shut Down, Restart, Force Off")
                }
            }
            .controlSize(.large)
            .disabled(busy)
            .animation(.smooth, value: item.status.state)
        }
    }
}

// MARK: - Sections

private struct HardwareSection: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item
    var edit: () -> Void

    var body: some View {
        let c = item.config
        let disk = model.diskInfo[c.name]
        GlassSection("Hardware", symbol: "cpu") {
            Button("Edit", action: edit)
        } content: {
            VStack(spacing: 9) {
                InfoRow("Processors", "\(c.cpuCount) cores")
                InfoRow("Memory", Format.memory(c.memoryMiB))
                InfoRow("Disk") {
                    if let disk {
                        Text("\(Format.bytes(disk.actualSize)) used of \(c.diskSizeGiB) GB")
                    } else {
                        Text("\(c.diskSizeGiB) GB")
                    }
                }
                if let disk {
                    ProgressView(value: min(1, Double(disk.actualSize) / Double(max(disk.virtualSize, 1))))
                        .tint(.accentColor)
                }
                InfoRow("Graphics", Format.graphics(c.graphicsBackend))
                InfoRow("Network") {
                    Text(c.isQuarantined && !c.allows(.network)
                         ? "Off (quarantined)"
                         : Format.network(c.network) + (c.portForwards.isEmpty ? "" : " · \(c.portForwards.count) forwards"))
                }
            }
        }
    }
}

private struct BootSection: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item
    var edit: () -> Void
    @State private var confirm: Confirm?

    enum Confirm: String, Identifiable {
        case firmware, tpm
        var id: String { rawValue }
    }

    var body: some View {
        let b = item.config.boot
        let stopped = !item.status.isActive
        GlassSection("Boot & Firmware", symbol: "memorychip") {
            if stopped {
                Menu {
                    Button("Reset UEFI Variables…") { confirm = .firmware }
                    Button("Clear TPM…") { confirm = .tpm }.disabled(!b.tpm)
                } label: {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .help("Reset UEFI variables or clear the TPM")
            }
        } content: {
            VStack(spacing: 9) {
                InfoRow("Boot order", Format.bootOrder(b.order))
                InfoRow("Firmware wait", b.firmwareTimeoutSeconds == 0 ? "None" : "\(b.firmwareTimeoutSeconds) s")
                InfoRow("TPM 2.0", b.tpm ? "On" : "Off")
                InfoRow("Secure Boot", "Not available")
                    .help("The firmware build has no Secure Boot yet (docs/01 D12).")
                Spacer(minLength: 0)
                if stopped {
                    HStack {
                        Button("Firmware Setup", systemImage: "cpu") { model.start(item.id, keys: .firmwareSetup) }
                            .help("Start and press Escape to open the UEFI menu")
                        Spacer()
                        Button("Change…", action: edit)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(.top, 2)
                } else {
                    Text("Shut down to change boot settings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
        .confirmationDialog(confirm == .tpm ? "Clear the TPM?" : "Reset UEFI variables?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { which in
            Button(which == .tpm ? "Clear TPM" : "Reset", role: .destructive) {
                which == .tpm ? model.resetTPM(item.id) : model.resetFirmware(item.id)
            }
        } message: { which in
            Text(which == .tpm
                 ? "BitLocker keys, Windows Hello PINs and anything else sealed to the TPM are lost."
                 : "Boot entries and firmware settings go back to defaults. Windows stays on the disk and boots through its fallback loader.")
        }
    }
}

private struct MediaSection: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item

    var body: some View {
        let stopped = !item.status.isActive
        GlassSection("Installer & Media", symbol: "opticaldisc") {
            if !stopped {
                Text("Changes apply at next start").font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            VStack(spacing: 10) {
                ForEach(item.config.media, id: \.path) { m in
                    HStack(spacing: 10) {
                        Image(systemName: m.kind == .cdrom ? "opticaldisc" : "externaldrive")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(m.exists ? m.url.deletingLastPathComponent().path(percentEncoded: false) : "File missing")
                                .font(.caption)
                                .foregroundStyle(m.exists ? Color.secondary : Color.red)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(m.kind == .cdrom ? "CD-ROM" : "USB Disk")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Eject", systemImage: "eject") { model.detach(item.id, path: m.path) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .disabled(!stopped)
                    }
                }
                if !item.config.allows(.files) {
                    Label("Quarantined: attaching disks and ISOs is off (Settings ▸ Quarantine ▸ Files).",
                          systemImage: "shield.lefthalf.filled")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if stopped {
                    ISODropZone(prompt: item.config.media.isEmpty
                                ? "Drop a Windows ISO or disk image to attach it"
                                : "Drop another ISO or image",
                                compact: !item.config.media.isEmpty) { url in
                        model.attach(item.id, files: [url])
                    }
                } else if item.config.media.isEmpty {
                    Text("No media attached.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct SnapshotSection: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item
    @State private var naming = false
    @State private var newName = ""
    @State private var reverting: String?

    var body: some View {
        let stopped = !item.status.isActive
        let snapshots = model.diskInfo[item.id]?.snapshots ?? []
        GlassSection("Snapshots", symbol: "clock.arrow.circlepath") {
            Button("Take Snapshot", systemImage: "plus") {
                newName = "snapshot-\(Date().formatted(.iso8601.year().month().day()))"
                naming = true
            }
            .disabled(!stopped)
            .help(stopped ? "Save the disk’s current state" : "Shut down to take a snapshot")
            .popover(isPresented: $naming, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Snapshot name").font(.headline)
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(create)
                    HStack {
                        Spacer()
                        Button("Cancel") { naming = false }
                        Button("Take Snapshot", action: create)
                            .buttonStyle(.glassProminent)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(16)
            }
        } content: {
            if snapshots.isEmpty {
                Text(stopped ? "No snapshots. Take one before trying something risky."
                             : "No snapshots.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshots, id: \.id) { s in
                        HStack {
                            Image(systemName: "camera.aperture").foregroundStyle(.secondary)
                            Text(s.name)
                            Spacer()
                            Text(s.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Menu {
                                Button("Revert to This Snapshot…") { reverting = s.name }
                                Button("Delete", role: .destructive) { model.snapshot(item.id, .delete, label: s.name) }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuIndicator(.hidden)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(!stopped)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Revert to “\(reverting ?? "")”?",
                            isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } })) {
            Button("Revert", role: .destructive) {
                if let label = reverting { model.snapshot(item.id, .revert, label: label) }
            }
        } message: {
            Text("Everything written to the disk since this snapshot is lost.")
        }
    }

    private func create() {
        let label = newName.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        naming = false
        model.snapshot(item.id, .create, label: label)
    }
}

private struct FilesSection: View {
    @Environment(AppModel.self) private var model
    var item: AppModel.Item

    var body: some View {
        GlassSection("Windows & Files", symbol: "folder") {
            EmptyView()
        } content: {
            HStack(spacing: 10) {
                if model.hasWindowsPassword(item.id) {
                    Button("Copy Windows Password", systemImage: "key") { model.copyWindowsPassword(item.id) }
                        .help("Password of the VM’s local Windows account, stored in your Keychain.")
                }
                Button("Logs", systemImage: "doc.text.magnifyingglass") { model.openLogs(item.id) }
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder(item.id) }
                Spacer()
                Text(item.config.macAddress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("MAC address")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

private struct BuildSection: View {
    @Environment(AppModel.self) private var model
    var name: String
    var progress: BuildProgress

    var body: some View {
        GlassSection("Automatic Install", symbol: "wand.and.stars") {
            switch progress.outcome {
            case .running:
                Button("Watch", systemImage: "display") { model.showDisplay(name) }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(progress.phase != .installing)
                    .help("Show the install in a window. Seemless needs no input; you can just wait.")
            default:
                Button("Dismiss") { model.dismissBuild(name) }
            }
        } content: {
            BuildProgressView(progress: progress, logHeight: 120)
        }
    }
}

/// Staged progress of an automatic install, used by the library and the
/// first-run flow.
struct BuildProgressView: View {
    var progress: BuildProgress
    var logHeight: CGFloat
    @State private var showLog = false

    private static let stages: [(ImageBuilder.Phase, String)] = [
        (.checkingMedia, "Check the Windows ISO"),
        (.preparing, "Create the VM and its setup disk"),
        (.installing, "Install Windows (about 5–15 minutes)"),
        (.finishing, "Finish"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, stage in
                HStack(spacing: 8) {
                    stageIcon(i)
                        .frame(width: 18)
                    Text(stage.1)
                        .foregroundStyle(state(i) == .pending ? .secondary : .primary)
                    if stage.0 == .installing, state(i) == .active {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(detailLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            switch progress.outcome {
            case .running:
                if !progress.hasDrivers {
                    Label("No 3D graphics driver found: Windows installs with basic graphics.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .finished(let status, let dir, let timedOut):
                if progress.succeeded {
                    Label("Windows is installed. It starts in its own window: accept Microsoft’s licence there.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(failureText(status: status, timedOut: timedOut), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Install Logs") { NSWorkspace.shared.open(dir) }
                    .buttonStyle(.glass).controlSize(.small)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Details", isExpanded: $showLog) {
                ScrollView {
                    Text(progress.lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: logHeight)
                .defaultScrollAnchor(.bottom)
            }
            .font(.callout)
        }
    }

    private enum StageState { case done, active, pending, failed }

    private func state(_ i: Int) -> StageState {
        let current = progress.phase.flatMap { p in Self.stages.firstIndex { $0.0 == p } } ?? -1
        switch progress.outcome {
        case .running:
            return i < current ? .done : i == current ? .active : .pending
        case .finished:
            if progress.succeeded { return .done }
            return i < Self.stages.count - 1 ? .done : .failed
        case .failed:
            return i < current ? .done : i == max(current, 0) ? .failed : .pending
        }
    }

    @ViewBuilder
    private func stageIcon(_ i: Int) -> some View {
        switch state(i) {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active: ProgressView().controlSize(.small)
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var detailLine: String {
        let elapsed = Int(Date().timeIntervalSince(progress.started))
        let written = ByteCountFormatter.string(fromByteCount: progress.diskBytes, countStyle: .file)
        return String(format: "%d:%02d · %@ written", elapsed / 60, elapsed % 60, written)
    }

    private func failureText(status: String?, timedOut: Bool) -> String {
        if timedOut { return "Windows Setup did not finish in time, so the VM was turned off. The install logs say how far it got." }
        guard let status else {
            return "Windows Setup never started from the ISO. Check that it is a Windows 11 ARM64 ISO, then delete this VM and try again."
        }
        if status.hasPrefix("ERROR") { return "Windows Setup reported an error (\(status)). The install logs have the details." }
        return "Install ended with status \(status)."
    }
}
