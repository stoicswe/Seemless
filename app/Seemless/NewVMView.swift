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
    /// No default: the person must choose (both are required).
    @State private var mode: Mode?
    @State private var profile: InstallProfile?
    @State private var showingAbout = false
    @State private var username = "Seemless"
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
                             destination: FirstRun.windowsDownloadPage)
                            .font(.callout)
                    }
                }

                Section {
                    Picker("Install", selection: $mode) {
                        Text("Automatic").tag(Optional(Mode.automatic))
                        Text("Manual").tag(Optional(Mode.manual))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch mode {
                    case nil:
                        Text("Automatic installs Windows by itself in about 5–15 minutes. Manual runs Microsoft’s own Setup for you to click through.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .automatic:
                        Text("Seemless installs Windows from the ISO with the 3D graphics driver, then starts it in its own window. The network stays off during install, so Windows never asks for a Microsoft account.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .manual:
                        Text("Creates a blank disk with the ISO attached and runs Windows Setup normally. Seemless presses a key at “Press any key to boot from CD” on the first start.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Start the VM now", isOn: $startNow)
                    }
                } header: {
                    RequiredHeader(title: "Install", satisfied: mode != nil)
                }

                if mode == .automatic {
                    Section {
                        ForEach(InstallProfile.allCases) { p in
                            ProfileRow(profile: p, selected: profile == p) { profile = p }
                        }
                    } header: {
                        HStack {
                            RequiredHeader(title: "Windows Profile", satisfied: profile != nil)
                            Spacer()
                            Button("About Profiles", systemImage: "info.circle") { showingAbout = true }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .popover(isPresented: $showingAbout, arrowEdge: .trailing) { ProfilesAboutView() }
                        }
                    }

                    Section {
                        TextField("Account name", text: $username)
                        if !SetupPayload.Settings.isValidUsername(username) {
                            Text("1–20 letters, digits, “.”, “_” or “-”; not Administrator or Guest.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Text("A local administrator account, no Microsoft account. Its password is generated and saved in your Keychain, and Windows signs in to it automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: {
                        Label("Windows Account", systemImage: "person.crop.circle")
                    }

                    Section {
                        Label("Windows shows Microsoft’s licence terms when it first starts. You read and accept them yourself in the Windows window; Seemless never accepts them for you.",
                              systemImage: "doc.text")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.drivers == nil {
                            Label("3D graphics driver not found: Windows installs with basic graphics only.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if model.assets == nil {
                            Label("Install scripts (image/) not found next to the app.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Name") {
                    TextField("Name", text: $config.name)
                    if model.item(config.name) != nil {
                        Text("A VM with this name exists.").font(.caption).foregroundStyle(.red)
                    }
                }

                HardwareFields(config: $config)

                QuarantineFields(config: $config, creating: true)

                let errors = problems
                if !errors.isEmpty, iso != nil {
                    Section {
                        ForEach(errors, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !missingChoices.isEmpty {
                    Label("Choose " + missingChoices.joined(separator: " and "), systemImage: "arrow.up")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
        .onAppear {
            // Developer switch for screenshot checks (see AppModel):
            // SEEMLESS_OPEN=new-vm-automatic / new-vm-about.
            switch ProcessInfo.processInfo.environment["SEEMLESS_OPEN"] {
            case "new-vm-automatic": mode = .automatic
            case "new-vm-about": mode = .automatic; showingAbout = true
            default: break
            }
        }
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

    /// Required choices not made yet, for the hint next to the button.
    private var missingChoices: [String] {
        var missing: [String] = []
        if mode == nil { missing.append("an install type") }
        if mode == .automatic, profile == nil { missing.append("a Windows profile") }
        if mode == .automatic, !SetupPayload.Settings.isValidUsername(username) { missing.append("a valid account name") }
        return missing
    }

    private var canCreate: Bool {
        guard !creating, model.item(config.name) == nil, problems.isEmpty, missingChoices.isEmpty else { return false }
        switch mode {
        case .automatic: return iso != nil && selectedImage?.isSupported == true && model.assets != nil
        case .manual: return !inspecting
        case nil: return false
        }
    }

    private func create() {
        creating = true
        let name = config.name.trimmingCharacters(in: .whitespaces)
        config.name = name
        switch mode {
        case nil:
            creating = false
        case .automatic:
            guard let iso, let profile else { creating = false; return }
            var request = ImageBuilder.Request(iso: iso, vm: config)
            request.imageIndex = edition
            request.recipe = profile.recipe
            request.username = username
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

// MARK: - Install section pieces

/// Section title with a "Required" marker that turns into a checkmark once
/// the choice is made.
private struct RequiredHeader: View {
    var title: String
    var satisfied: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if satisfied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("chosen")
            } else {
                Text("Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .capsule)
            }
        }
    }
}

/// One selectable profile: radio-style, whole row clickable.
struct ProfileRow: View {
    var profile: InstallProfile
    var selected: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.title).font(.body.weight(.medium))
                    Text(profile.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What each profile removes and keeps (image/recipes/README.md).
struct ProfilesAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Windows Profiles").font(.title3.weight(.semibold))
                Text("A profile decides what is removed from Windows while it installs. You can still install anything later from the Microsoft Store or with winget.")
                    .font(.callout).foregroundStyle(.secondary)

                profile("Lean", symbol: "leaf", tint: .green,
                        removes: ["Promotional apps: Clipchamp, News, Weather, Bing Search, Solitaire, Office and Outlook promos, Teams, To Do, Sticky Notes, Dev Home, Feedback Hub, Get Help, Quick Assist, Media Player",
                                  "Phone Link, the widgets board, Xbox apps",
                                  "Legacy extras: Internet Explorer mode, Steps Recorder, Windows Hello face, Math Input, old Windows Media Player, PowerShell ISE, extra wallpapers",
                                  "The Edge browser (install another one with Open in Seemless)",
                                  "Ads, suggested apps, Copilot, Teams auto-install, reserved storage, automatic BitLocker, OneDrive setup"],
                        keeps: "Microsoft Store, winget, media codecs, Defender, x64 app emulation, DirectX, WebView2 (used inside many apps), Calculator, Notepad, Paint, Photos, Terminal, Snipping Tool, Camera")

                profile("Lean, with Xbox", symbol: "gamecontroller", tint: .blue,
                        removes: ["Everything Lean removes, except the items below"],
                        keeps: "Also keeps the Xbox apps (Game Pass, Xbox sign-in in games, Game Bar) and legacy Windows Media Player, which some older games use for cutscenes")

                profile("Fat", symbol: "shippingbox", tint: .orange,
                        removes: ["Nothing"],
                        keeps: "Windows 11 exactly as on the ISO. Larger and busier, but nothing missing. Useful for comparison or when an app needs something the lean profiles remove")

                Text("Every profile installs unattended, uses a local account, keeps Windows Update and Defender, and shows Microsoft’s licence page on first start for you to accept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 420, height: 520)
    }

    private func profile(_ title: String, symbol: String, tint: Color, removes: [String], keeps: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Removes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(removes, id: \.self) { Text("• " + $0).font(.callout) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Keeps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(keeps).font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
