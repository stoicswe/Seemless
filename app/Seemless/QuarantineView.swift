import SeemlessKit
import SwiftUI

/// Quarantine controls (owner, 2026-11-24; docs/07 "Quarantine").
///
/// New VM sheet: the choice to quarantine, which is only offered at
/// creation. Settings: one switch per connection, and lifting quarantine
/// (while the VM is stopped, after a warning). "Off" leaves the device out
/// of the VM, so changes apply at the next start.
struct QuarantineFields: View {
    @Binding var config: VMConfig
    /// True in the New VM sheet: shows the on/off choice instead of the switches.
    var creating = false
    @State private var confirmingLift = false

    var body: some View {
        if creating {
            Section {
                Toggle(isOn: quarantined) {
                    Text("Quarantine this VM")
                    Text("No connection to your Mac except keyboard, mouse and display: no network, clipboard, files, sound or guest agent. Turn single connections on later in Settings.")
                }
            } header: {
                Text("Isolation")
            }
        } else if config.quarantine != nil {
            Section {
                toggle("Network", "Internet access through a network card.", \.network)
                toggle("Guest agent", "Needed for Zen mode, window information and a clean shutdown. Clipboard and files use it too.", \.agent)
                toggle("Clipboard: Mac to Windows", "Needs the guest agent.", \.clipboardToGuest)
                    .disabled(config.quarantine?.agent != true)
                toggle("Clipboard: Windows to Mac", "Needs the guest agent.", \.clipboardToHost)
                    .disabled(config.quarantine?.agent != true)
                toggle("Files", "Attaching disks or ISOs, drag and drop and opening Mac files in Windows (the last two need the guest agent).", \.files)
                toggle("Sound", "Sound out. There is no microphone device yet.", \.audio)
                Button("Lift Quarantine…", role: .destructive) { confirmingLift = true }
            } header: {
                Label("Quarantine", systemImage: "shield.lefthalf.filled")
            } footer: {
                Text("Keyboard, mouse and display are always on. A connection that is off has no device in the VM; changes apply at the next start.")
            }
            .confirmationDialog("Lift quarantine for “\(config.name)”?", isPresented: $confirmingLift) {
                Button("Lift Quarantine", role: .destructive) { config.quarantine = nil }
            } message: {
                Text("At its next start the VM gets every connection a normal VM has: network, guest agent, clipboard, files and sound. Anything running in Windows can then reach your Mac through them.")
            }
        }
    }

    private var quarantined: Binding<Bool> {
        Binding(get: { config.quarantine != nil },
                set: { config.quarantine = $0 ? .isolated : nil })
    }

    private func toggle(_ title: String, _ detail: String, _ key: WritableKeyPath<Quarantine, Bool>) -> some View {
        Toggle(isOn: Binding(get: { config.quarantine?[keyPath: key] ?? false },
                             set: { config.quarantine?[keyPath: key] = $0 })) {
            Text(title)
            Text(detail)
        }
    }
}

/// A small "Quarantined" chip for the VM header.
struct QuarantineBadge: View {
    var body: some View {
        Label("Quarantined", systemImage: "shield.lefthalf.filled")
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glassEffect(.regular.tint(Color.orange.opacity(0.12)), in: .capsule)
            .fixedSize()
    }
}
