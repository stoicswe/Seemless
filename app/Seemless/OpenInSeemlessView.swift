import SeemlessKit
import SwiftUI

/// Confirms running Windows installers from the Mac inside a VM
/// ("Open in Seemless", `GuestLaunch`).
struct OpenInSeemlessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.LaunchRequest
    @State private var target: String?
    @State private var sending = false
    @State private var result: Outcome?

    enum Outcome { case sent, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open in Seemless").font(.title2.weight(.semibold))
                    Text("Run \(request.files.count == 1 ? "this installer" : "these installers") in Windows.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                ForEach(request.files, id: \.self) { file in
                    HStack(spacing: 10) {
                        Image(systemName: "app.badge")
                            .foregroundStyle(.secondary)
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(size(of: file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(request.rejected, id: \.self) { file in
                    Label("\(file.lastPathComponent) is not a Windows installer (.exe or .msi) and is skipped",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))

            if model.items.isEmpty {
                Label("Create a virtual machine first.", systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                Picker("Virtual machine", selection: $target) {
                    ForEach(model.items) { item in
                        Text("\(item.id) — \(item.status.state.label)").tag(Optional(item.id))
                    }
                }
                .disabled(sending || result != nil)
            }

            Text(explanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch result {
            case .sent:
                Label("Sent. The installer opens in Windows in a few seconds. If it does not, open the SLRUN drive in File Explorer and run it (or run “Enable automatic installs” there once).",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }

            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                if case .sent = result {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(actionTitle) { send() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(target == nil || request.files.isEmpty || sending)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { target = target ?? model.defaultLaunchTarget }
    }

    private var targetState: VMProcess.State? { target.flatMap { model.item($0)?.status.state } }

    private var actionTitle: String {
        switch targetState {
        case .stopped, .crashed: return "Start and Install"
        case .paused: return "Resume and Install"
        default: return "Install"
        }
    }

    private var explanation: String {
        let start: String
        switch targetState {
        case .stopped, .crashed: start = "The VM starts first. "
        case .paused: start = "The VM resumes first. "
        default: start = ""
        }
        return start + "Seemless plugs a small read-only USB drive with the installer into the VM; Windows copies it and starts it once you are logged on. Only run installers you trust: they run with administrator rights in Windows."
    }

    private func size(of file: URL) -> String {
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func send() {
        guard let target else { return }
        sending = true
        result = nil
        Task {
            if let message = await model.sendInstallers(request.files, to: target) {
                result = .failed(message)
            } else {
                result = .sent
            }
            sending = false
        }
    }
}
