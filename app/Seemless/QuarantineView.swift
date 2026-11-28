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

/// The experimental WacOS option of an automatic install (owner,
/// 2026-11-24; SeemlessKit `WacOSRelease`). Seemless ships none of WacOS:
/// Windows downloads the official release after setup. Its licence is the
/// person's to accept, so the switch alone is not enough.
struct WacOSFields: View {
    @Binding var enabled: Bool
    @Binding var licenseAccepted: Bool
    var networkAvailable: Bool

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Text("Mac-style desktop (WacOS)")
                Text("Replaces the Windows taskbar and Start menu with WacOS’s menu bar, Dock, Finder and Spotlight. Windows downloads WacOS \(WacOSRelease.pinned.tag) from its GitHub releases at the first sign-in once the network is on (about 190 MB).")
            }
            .disabled(!networkAvailable)
            if !networkAvailable {
                Text("Needs the network: this VM is quarantined with its network off.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if enabled {
                Toggle(isOn: $licenseAccepted) {
                    Text("I accept the WacOS licence")
                    Text("WacOS is a separate project, source-available for personal, non-commercial use only. It is not part of Seemless and Seemless does not maintain it.")
                }
                Link("Read the WacOS licence", destination: WacOSRelease.licenseURL)
                    .font(.callout)
                Label("Zen mode is off for VMs with WacOS for now.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Desktop")
                ExperimentalBadge()
            }
        }
    }
}

/// A small "Experimental" chip.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: .capsule)
            .fixedSize()
    }
}
