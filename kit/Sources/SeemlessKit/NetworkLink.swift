import Foundation

/// Plugging the VM's virtual network cable in or out while it runs
/// (docs/02 "Network link"; owner request 2026-11-24).
///
/// QMP `set_link` on the netdev also takes the virtio-net NIC's link down,
/// so Windows sees "Network cable unplugged" and stops all traffic; the
/// network settings themselves are untouched. QEMU has no query for the link
/// state, so the state is recorded in the run directory: it lives only as
/// long as the VM runs, and every start begins connected unless the config
/// asks for an offline first setup.
public enum NetworkLink {
    /// The netdev id `QEMUCommand` gives the VM's network (`-netdev …,id=n0`).
    public static let netdevID = "n0"

    /// The QMP arguments for `set_link`.
    public static func setLinkArguments(up: Bool) -> [String: JSONValue] {
        ["name": .string(netdevID), "up": .bool(up)]
    }

    /// Plugs the cable in (`true`) or out, and records the new state.
    public static func set(connected: Bool, qmp: QMPClient, run: RunPaths) async throws {
        _ = try await qmp.execute("set_link", arguments: setLinkArguments(up: connected))
        try record(connected: connected, run: run)
    }

    /// Whether the cable is plugged in, as last set on this run. A run that
    /// never changed it is connected.
    public static func isConnected(run: RunPaths) -> Bool {
        guard let data = try? Data(contentsOf: run.networkLink) else { return true }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "disconnected"
    }

    static func record(connected: Bool, run: RunPaths) throws {
        try Data((connected ? "connected\n" : "disconnected\n").utf8).write(to: run.networkLink, options: .atomic)
    }
}
