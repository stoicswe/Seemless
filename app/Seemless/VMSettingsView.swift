import SeemlessKit
import SwiftUI

/// Edits a copy of the config; saving goes through `VMManager.update`,
/// which grows the disk if needed. Read-only while the VM runs.
struct VMSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: VMConfig
    let locked: Bool
    @State private var config: VMConfig
    @State private var saving = false

    init(original: VMConfig, locked: Bool) {
        self.original = original
        self.locked = locked
        _config = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if locked {
                    Section {
                        Label("Shut down the VM to change its settings.", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                HardwareFields(config: $config, minimumDiskGiB: original.diskSizeGiB)
                    .disabled(locked)
                Section("Boot & Firmware") {
                    Picker("Boot order", selection: $config.boot.order) {
                        ForEach(VMConfig.BootSettings.Order.allCases, id: \.self) { Text(Format.bootOrder($0)) }
                    }
                    Stepper(value: $config.boot.firmwareTimeoutSeconds, in: 0...30) {
                        LabeledContent("Firmware menu wait",
                                       value: config.boot.firmwareTimeoutSeconds == 0 ? "None" : "\(config.boot.firmwareTimeoutSeconds) s")
                    }
                    Toggle(isOn: $config.boot.tpm) {
                        Text("TPM 2.0")
                        Text("Windows 11 requires a TPM. Turn off only to troubleshoot.")
                    }
                }
                .disabled(locked)
                Section("Graphics & Network") {
                    Picker("Direct3D backend", selection: $config.graphicsBackend) {
                        ForEach(VMConfig.GraphicsBackend.allCases, id: \.self) { Text(Format.graphics($0)) }
                    }
                    if config.quarantine?.network == false {
                        Label("Quarantine has the network off: the VM gets no network card.", systemImage: "shield.lefthalf.filled")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Network", selection: $config.network) {
                        Text(Format.network(.user)).tag(VMConfig.NetworkMode.user)
                        Text(Format.network(.vmnetShared)).tag(VMConfig.NetworkMode.vmnetShared)
                        Text(Format.network(.none)).tag(VMConfig.NetworkMode.none)
                    }
                    if config.network == .user {
                        PortForwardsEditor(forwards: $config.portForwards)
                    }
                    LabeledContent("MAC address") {
                        Text(config.macAddress).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
                .disabled(locked)
                QuarantineFields(config: $config)
                    .disabled(locked)
                let errors = config.validationErrors()
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if config.diskSizeGiB > original.diskSizeGiB {
                    Label("The disk grows to \(config.diskSizeGiB) GB. Extend the partition in Windows afterwards.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        if await model.save(config) { dismiss() }
                        saving = false
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(locked || saving || config == original || !config.validationErrors().isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .navigationTitle("\(original.name) Settings")
    }
}

/// CPU, memory and disk controls, shared with the New VM sheet.
struct HardwareFields: View {
    @Binding var config: VMConfig
    var minimumDiskGiB: Int = 32
    private let host = HostInfo.current

    var body: some View {
        Section("Hardware") {
            let maxMemoryGiB = max(4, (host.memoryMiB - 2048) / 1024)
            LabeledContent("Processors") {
                HStack {
                    Slider(value: Binding(get: { Double(config.cpuCount) }, set: { config.cpuCount = Int($0) }),
                           in: 1...Double(host.logicalCores), step: 1)
                    Text("\(config.cpuCount)").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
            LabeledContent("Memory") {
                HStack {
                    Slider(value: Binding(get: { Double(config.memoryMiB / 1024) }, set: { config.memoryMiB = Int($0) * 1024 }),
                           in: 4...Double(maxMemoryGiB), step: 1)
                    Text(Format.memory(config.memoryMiB)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            LabeledContent("Disk size") {
                HStack {
                    Slider(value: Binding(get: { Double(config.diskSizeGiB) }, set: { config.diskSizeGiB = Int($0) }),
                           in: Double(minimumDiskGiB)...Double(max(minimumDiskGiB + 32, 512)), step: 8)
                    Text("\(config.diskSizeGiB) GB").monospacedDigit().frame(width: 58, alignment: .trailing)
                }
            }
            Text("Recommended: \(host.defaultVCPUs) processors and \(Format.memory(host.defaultMemoryMiB)) on this Mac. Disks grow as Windows uses them and can only be made larger.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PortForwardsEditor: View {
    @Binding var forwards: [VMConfig.PortForward]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Port forwards")
                Spacer()
                Button("Add", systemImage: "plus") {
                    forwards.append(.init(hostPort: 3389, guestPort: 3389))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            if forwards.isEmpty {
                Text("None. Forwarded ports listen on 127.0.0.1 only.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(forwards.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Picker("", selection: $forwards[i].proto) {
                        Text("TCP").tag(VMConfig.PortForward.Proto.tcp)
                        Text("UDP").tag(VMConfig.PortForward.Proto.udp)
                    }
                    .labelsHidden().frame(width: 70)
                    TextField("Mac", value: $forwards[i].hostPort, format: .number.grouping(.never))
                        .frame(width: 70)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Windows", value: $forwards[i].guestPort, format: .number.grouping(.never))
                        .frame(width: 70)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { forwards.remove(at: i) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}
