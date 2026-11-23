import Foundation

/// Keys pressed over QMP right after the vCPUs start, to answer prompts that
/// appear before any guest agent exists.
///
/// - `cdPrompt`: Windows media wait about five seconds at "Press any key to
///   boot from CD or DVD" and then give up. Only use it when booting media is
///   intended: on a disk that already boots, the key reruns Windows Setup.
/// - `firmwareSetup`: Escape during the edk2 logo opens the firmware menu
///   (boot manager, boot order, device manager, Secure Boot keys later).
public enum BootKeys: String, Sendable, Equatable, CaseIterable {
    case cdPrompt
    case firmwareSetup

    /// QEMU qcode sent repeatedly.
    public var qcode: String {
        switch self {
        case .cdPrompt: return "spc"
        case .firmwareSetup: return "esc"
        }
    }

    /// How long to keep pressing.
    public var duration: Duration {
        switch self {
        case .cdPrompt: return .seconds(40)
        case .firmwareSetup: return .seconds(8)
        }
    }

    public static let interval: Duration = .milliseconds(400)

    /// Presses `qcode` every `interval` until `duration` passes or the
    /// connection closes. Returns immediately; the task can be cancelled.
    @discardableResult
    public func press(on qmp: QMPClient) -> Task<Void, Never> {
        let qcode = self.qcode
        let end = ContinuousClock.now + duration
        return Task {
            while ContinuousClock.now < end, !Task.isCancelled {
                guard await qmp.isConnected else { return }
                _ = try? await qmp.execute("send-key", arguments: ["keys": [["type": "qcode", "data": .string(qcode)]]])
                try? await Task.sleep(for: Self.interval)
            }
        }
    }
}
