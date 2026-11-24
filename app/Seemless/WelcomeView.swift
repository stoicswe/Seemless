import SeemlessKit
import SwiftUI

/// First run without Terminal (WP3.4, docs/07 "First run"): what Seemless
/// needs, the person's own Windows ISO, a profile, then the automatic
/// install with staged progress, ending with Windows started in its desktop
/// window where the person accepts Microsoft's licence themselves.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    enum Step { case requirements, setup, installing }

    @State private var step: Step = .requirements
    @State private var facts: FirstRun.HostFacts?
    @State private var iso: URL?
    @State private var inspection: Result<ISOMedia.Inspection, Error>?
    @State private var inspecting = false
    @State private var profile: InstallProfile?
    @State private var username = "Seemless"
    @State private var vmName = "Windows 11"
    @State private var switchesDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                switch step {
                case .requirements: requirementsStep
                case .setup: setupStep
                case .installing: installingStep
                }
            }
            .padding(36)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(WindowBackdrop(tint: .accentColor))
        .task {
            if facts == nil {
                facts = FirstRun.HostFacts.current(storageRoot: model.layout.root, stack: model.manager?.stack,
                                                   assets: model.assets, drivers: model.drivers)
            }
            await runSwitches()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch step {
        case .requirements: "Welcome to Seemless"
        case .setup: "Your Windows installer"
        case .installing: "Installing Windows"
        }
    }

    private var subtitle: String {
        switch step {
        case .requirements: "Windows 11 for Arm in a virtual machine on your Mac."
        case .setup: "Seemless installs Windows from your own ISO. Nothing from Microsoft is included."
        case .installing: "This takes about 5–15 minutes. You can use your Mac meanwhile."
        }
    }

    // MARK: Step 1: requirements

    private var requirementsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What you need").font(.headline)
                    if let facts {
                        ForEach(FirstRun.requirements(facts)) { r in requirementRow(r) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("About the Windows licence", systemImage: "doc.text").font(.headline)
                    Text("Windows needs a licence of your own. When Windows first starts it shows Microsoft’s licence terms: you read and accept them yourself in the Windows window. Seemless never accepts them for you.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if !model.items.isEmpty {
                    Button("Go to Library") { model.showingWelcome = false }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Continue") { step = .setup }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(facts.map(FirstRun.canInstall) ?? false))
            }
        }
    }

    private func requirementRow(_ r: FirstRun.Requirement) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if r.id == .windowsISO {
                    Image(systemName: "opticaldisc").foregroundStyle(Color.accentColor)
                } else if r.met {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if r.blocking {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.title3)
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.body.weight(.medium))
                Text(r.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if r.id == .windowsISO {
                    Link("Get Windows 11 for Arm from Microsoft", destination: FirstRun.windowsDownloadPage)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Step 2: ISO and profile

    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Windows 11 ARM64 ISO").font(.headline)
                    if let iso {
                        isoSummary(iso)
                    } else {
                        ISODropZone(prompt: "Drop your Windows 11 ARM64 ISO here") { pick($0) }
                        Text("Download “Windows 11 (multi-edition ISO for Arm64)” from Microsoft, then drop the file here.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("Open Microsoft’s download page", destination: FirstRun.windowsDownloadPage)
                            .font(.callout)
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Windows profile").font(.headline)
                        if profile == nil {
                            Text("Required").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                    ForEach(InstallProfile.allCases) { p in
                        ProfileRow(profile: p, selected: profile == p) { profile = p }
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Windows account").font(.headline)
                    TextField("Account name", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    if !SetupPayload.Settings.isValidUsername(username) {
                        Text("1–20 letters, digits, “.”, “_” or “-”; not Administrator or Guest.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("A local account, no Microsoft account. Its password is saved in your Keychain and Windows signs in by itself. The VM gets \(VMConfig().cpuCount) CPUs, \(VMConfig().memoryMiB / 1024) GB of memory and a 64 GB disk; change them later in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.drivers == nil {
                Label("The 3D graphics driver was not found, so Windows installs with basic graphics only (no 3D, no resizing).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Back") { step = .requirements }
                    .buttonStyle(.glass)
                Spacer()
                Button("Install Windows") { install() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
    }

    @ViewBuilder
    private func isoSummary(_ iso: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(iso.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if inspecting {
                    Text("Reading the ISO…").font(.caption).foregroundStyle(.secondary)
                } else if let problem = isoProblem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if let image = chosenImage {
                    Text("\(image.name) · build \(image.build).\(image.spBuild) · \(image.architecture.description) · \(image.defaultLanguage ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if inspecting { ProgressView().controlSize(.small) }
            Button("Change") { self.iso = nil; inspection = nil }
                .buttonStyle(.glass).controlSize(.small)
        }
    }

    private func pick(_ url: URL) {
        iso = url
        inspection = nil
        inspecting = true
        Task {
            let result: Result<ISOMedia.Inspection, Error>
            do { result = .success(try await ISOMedia.inspect(url)) } catch { result = .failure(error) }
            inspection = result
            inspecting = false
        }
    }

    /// Pro, else the first supported edition (as the builder picks).
    private var chosenImage: WIMInfo.Image? {
        guard case .success(let r) = inspection else { return nil }
        return r.wim.preferredImage
    }

    private var isoProblem: String? {
        switch inspection {
        case .failure(let error):
            return "This file is not usable Windows media: \(error)"
        case .success(let r):
            if r.wim.preferredImage == nil {
                let why = Set(r.wim.images.flatMap(\.unsupportedReasons)).sorted().joined(separator: "; ")
                return "No edition on this ISO can be used: \(why). Seemless needs Windows 11 for Arm64."
            }
            return nil
        case nil:
            return nil
        }
    }

    private var canInstall: Bool {
        iso != nil && !inspecting && chosenImage != nil && profile != nil
            && SetupPayload.Settings.isValidUsername(username) && model.assets != nil
    }

    private var uniqueName: String {
        var name = vmName
        var n = 2
        while model.item(name) != nil { name = "\(vmName) \(n)"; n += 1 }
        return name
    }

    private func install() {
        guard let iso, let profile else { return }
        let name = uniqueName
        vmName = name
        var request = ImageBuilder.Request(iso: iso, vm: VMConfig(name: name))
        request.imageIndex = chosenImage?.index
        request.recipe = profile.recipe
        request.username = username
        model.createAutomatic(request, startWhenDone: true)
        step = .installing
    }

    // MARK: Step 3: progress

    private var installingStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress = model.builds[vmName] {
                GlassCard {
                    BuildProgressView(progress: progress, logHeight: 200)
                }
                if progress.outcome == .running, progress.phase == .installing {
                    Button("Watch the Install", systemImage: "display") { model.showDisplay(vmName) }
                        .buttonStyle(.glass)
                        .help("Optional: Seemless needs no input until Windows starts.")
                }
                if progress.succeeded {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Next: accept the licence in Windows", systemImage: "hand.point.up.left")
                                .font(.headline)
                            Text("Windows is starting in its own window. It shows Microsoft’s licence terms: read them and click Accept there. Then Windows signs in to “\(username)”.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Tips: ⌘C, ⌘V and the other ⌘ shortcuts act as Ctrl in Windows; tap ⌘ alone for Start. The Display menu sends Ctrl-Alt-Delete and switches full screen. Resize the window and Windows follows.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    if case .running = progress.outcome {} else if !progress.succeeded {
                        Button("Delete and Start Over", role: .destructive) {
                            model.dismissBuild(vmName)
                            model.delete(vmName)
                            step = .setup
                        }
                        .buttonStyle(.glass)
                    }
                    Spacer()
                    if progress.succeeded {
                        Button("Show Windows") { model.showDisplay(vmName) }
                            .buttonStyle(.glass)
                    }
                    Button("Go to Library") {
                        model.selection = vmName
                        model.showingWelcome = false
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: Developer switches

    /// SEEMLESS_FIRSTRUN_ISO=<path> picks the ISO (and moves to step 2),
    /// SEEMLESS_FIRSTRUN_PROFILE=lean|leanXbox|fat picks the profile, and
    /// SEEMLESS_FIRSTRUN_GO=1 presses Install Windows once both are ready.
    /// They drive the same state the buttons do (no UI automation here).
    private func runSwitches() async {
        guard !switchesDone else { return }
        switchesDone = true
        let env = ProcessInfo.processInfo.environment
        if env["SEEMLESS_OPEN"] == "welcome-setup" { step = .setup }
        guard let path = env["SEEMLESS_FIRSTRUN_ISO"] else { return }
        try? await Task.sleep(for: .seconds(1))
        step = .setup
        pick(URL(filePath: path))
        if let p = env["SEEMLESS_FIRSTRUN_PROFILE"].flatMap(InstallProfile.init(rawValue:)) { profile = p }
        guard env["SEEMLESS_FIRSTRUN_GO"] == "1" else { return }
        while inspecting { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        if canInstall { install() }
    }
}

/// A rounded glass panel for the welcome steps.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
