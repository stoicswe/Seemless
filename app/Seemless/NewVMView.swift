import SeemlessKit
import SwiftUI

/// New VM: pick an ISO (inspected for editions), size the VM, choose an
/// automatic (docs/03 unattended) or manual install.
struct NewVMView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case automatic, manual
        var id: String { rawValue }
    }

    @State private var config = VMConfig(name: "Windows 11")
    @State private var iso: URL?
    @State private var inspection: Result<ISOMedia.Inspection, Error>?
    @State private var inspecting = false
    @State private var edition: Int?
    @State private var mode: Mode = .automatic
    @State private var acceptLicense = false
    @State private var startNow = true
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Windows Installer") {
                    if let iso {
                        isoSummary(iso)
                    } else {
                        ISODropZone(prompt: "Drop a Windows 11 ARM64 ISO here") { pick($0) }
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 4)
                        Link("Get Windows 11 for Arm from Microsoft",
                             destination: URL(string: "https://www.microsoft.com/software-download/windows11arm64")!)
                            .font(.callout)
                    }
                }

                Section("Name") {
                    TextField("Name", text: $config.name)
                    if model.item(config.name) != nil {
                        Text("A VM with this name exists.").font(.caption).foregroundStyle(.red)
                    }
                }

                HardwareFields(config: $config)

                Section("Install") {
                    Picker("Install", selection: $mode) {
                        Text("Automatic").tag(Mode.automatic)
                        Text("Manual").tag(Mode.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch mode {
                    case .automatic:
                        Text("Seemless applies Windows from the ISO, creates the account “Seemless” with a password saved in your Keychain, and shuts the VM down when setup finishes. The network stays off during install.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle(isOn: $acceptLicense) {
                            Text("I accept the Microsoft Software License Terms now")
                            Text("Off: Windows shows its licence page during setup for you to accept there.")
                        }
                        if model.assets == nil {
                            Label("Install scripts (image/) not found next to the app.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    case .manual:
                        Text("Creates a blank disk with the ISO attached and runs Windows Setup normally. Seemless presses a key at “Press any key to boot from CD” on the first start.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Start the VM now", isOn: $startNow)
                    }
                }

                let errors = problems
                if !errors.isEmpty, iso != nil {
                    Section {
                        ForEach(errors, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .automatic ? "Install Windows" : "Create") { create() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(width: 560, height: 720)
    }

    // MARK: ISO

    @ViewBuilder
    private func isoSummary(_ iso: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(iso.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if inspecting {
                    Text("Reading editions…").font(.caption).foregroundStyle(.secondary)
                } else if case .failure(let error) = inspection {
                    Text(String(describing: error)).font(.caption).foregroundStyle(.red).lineLimit(3)
                } else if let image = selectedImage {
                    Text("Build \(image.build).\(image.spBuild) · \(image.architecture.description) · \(image.defaultLanguage ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if inspecting { ProgressView().controlSize(.small) }
            Button("Change") {
                self.iso = nil
                inspection = nil
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        if case .success(let result) = inspection {
            Picker("Edition", selection: $edition) {
                ForEach(result.wim.images, id: \.index) { image in
                    Text(image.isSupported ? image.name : "\(image.name) (not supported)")
                        .tag(Optional(image.index))
                }
            }
        }
    }

    private func pick(_ url: URL) {
        iso = url
        inspection = nil
        edition = nil
        inspecting = true
        Task {
            let result: Result<ISOMedia.Inspection, Error>
            do { result = .success(try await ISOMedia.inspect(url)) } catch { result = .failure(error) }
            inspection = result
            if case .success(let r) = result { edition = r.wim.preferredImage?.index }
            inspecting = false
        }
    }

    private var selectedImage: WIMInfo.Image? {
        guard case .success(let r) = inspection else { return nil }
        return r.wim.images.first { $0.index == edition }
    }

    // MARK: Create

    private var problems: [String] {
        var errors = config.validationErrors()
        if case .failure = inspection { errors.append("This file is not usable Windows media.") }
        if let image = selectedImage, !image.isSupported { errors += image.unsupportedReasons }
        return errors
    }

    private var canCreate: Bool {
        guard !creating, model.item(config.name) == nil, problems.isEmpty else { return false }
        switch mode {
        case .automatic: return iso != nil && selectedImage?.isSupported == true && model.assets != nil
        case .manual: return !inspecting
        }
    }

    private func create() {
        creating = true
        let name = config.name.trimmingCharacters(in: .whitespaces)
        config.name = name
        switch mode {
        case .automatic:
            guard let iso else { return }
            var request = ImageBuilder.Request(iso: iso, vm: config)
            request.imageIndex = edition
            request.acceptWindowsLicense = acceptLicense
            model.createAutomatic(request)
            dismiss()
        case .manual:
            Task {
                if await model.createManual(config, iso: iso, startNow: startNow) { dismiss() }
                creating = false
            }
        }
    }
}
