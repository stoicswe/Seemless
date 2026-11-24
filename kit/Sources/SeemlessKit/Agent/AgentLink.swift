import CoreFoundation
import Foundation

/// The Mac's appearance, as Windows' theme should follow it (WP4.4).
public enum HostAppearance: Sendable, Equatable {
    case light, dark

    /// The current system appearance. Read from the global preferences
    /// (`AppleInterfaceStyle` = "Dark"), so it works in the CLI without
    /// AppKit; synchronised first, so a change made in System Settings is
    /// seen by a running process.
    public static var current: HostAppearance {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return style?.caseInsensitiveCompare("Dark") == .orderedSame ? .dark : .light
    }

    var proto: Seemless_V1_Appearance { self == .dark ? .dark : .light }
}

/// Keeps a running VM's Windows in step with the Mac (docs/06 "System",
/// WP4.4): the clock (`TimeSync`), the appearance (`SetHostInfo`), and the
/// end of an offline first setup once `SessionState` reports a signed-in
/// desktop.
///
/// QEMU's agent chardev serves one client at a time, so the link never
/// holds it: each sync is a short connection (Hello, the `SessionState`
/// the service sends after it, `TimeSync`, `SetHostInfo`, close). It syncs
/// every `interval` (`setupInterval` while the offline setup is pending),
/// when the Mac's appearance changes (checked every `tick`), and on
/// `syncNow()` (after resume). A VM without an agent channel (quarantine,
/// or none installed) is normal: syncs just fail quietly.
public actor AgentLink {
    public struct Configuration: Sendable {
        public var socket: URL
        /// Whether an offline first setup is waiting for the desktop.
        public var finishSetupWhenSignedIn: Bool
        public var interval: Duration = .seconds(300)
        public var setupInterval: Duration = .seconds(5)
        public var tick: Duration = .seconds(2)
        public var helloTimeout: Duration = .seconds(4)
        /// Injected for tests; the Mac's appearance by default.
        public var appearance: @Sendable () -> HostAppearance = { HostAppearance.current }
        public var now: @Sendable () -> Date = { Date() }
        /// Debugging: leave out TimeSync / SetHostInfo.
        public var sendTime = true
        public var sendHostInfo = true
        /// Checked every tick; the link ends once it returns false (VM gone).
        public var keepRunning: @Sendable () async -> Bool = { true }

        public init(socket: URL, finishSetupWhenSignedIn: Bool) {
            self.socket = socket
            self.finishSetupWhenSignedIn = finishSetupWhenSignedIn
        }
    }

    /// What one sync saw and did.
    public struct SyncResult: Sendable, Equatable {
        public var agentBuild: String
        public var session: Seemless_V1_SessionState?
        public var timeSynced: Bool
        public var appearanceSent: HostAppearance?
    }

    private var config: Configuration
    private let onSignedInDesktop: @Sendable () async -> Void
    private let log: @Sendable (String) -> Void
    private var lastAppearance: HostAppearance?
    private var lastSync: ContinuousClock.Instant?
    private var lastSession: Seemless_V1_SessionState?
    private var wake: AsyncStream<Void>.Continuation?
    private var failures = 0

    public init(_ config: Configuration, log: @escaping @Sendable (String) -> Void = { _ in },
                onSignedInDesktop: @escaping @Sendable () async -> Void) {
        self.config = config
        self.log = log
        self.onSignedInDesktop = onSignedInDesktop
    }

    /// The desktop is usable: someone (not OOBE's temporary `defaultuser0`)
    /// is signed in, and the session is neither locked nor on the secure
    /// desktop.
    public static func isSignedInDesktop(_ s: Seemless_V1_SessionState) -> Bool {
        let user = s.user.trimmingCharacters(in: .whitespaces).lowercased()
        return s.loggedOn && !s.locked && !s.secureDesktop && !user.isEmpty && !user.hasPrefix("defaultuser")
    }

    /// Syncs at once (after resume, or when the caller knows something changed).
    public func syncNow() { wake?.yield() }

    /// Runs until cancelled.
    public func run() async {
        let (stream, cont) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wake = cont
        let ticker = Task { [tick = config.tick] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                cont.yield()
            }
        }
        defer { ticker.cancel(); cont.finish() }
        await syncIfDue(force: true)
        for await _ in stream {
            if Task.isCancelled { break }
            guard await config.keepRunning() else { break }
            await syncIfDue(force: false)
        }
    }

    private func syncIfDue(force: Bool) async {
        let appearance = config.appearance()
        let every = config.finishSetupWhenSignedIn ? config.setupInterval : config.interval
        let due = lastSync.map { ContinuousClock.now - $0 >= every } ?? true
        guard force || due || appearance != lastAppearance else { return }
        _ = await sync(appearance: appearance)
    }

    /// One short connection. Returns nil when no agent answered.
    @discardableResult
    public func sync(appearance: HostAppearance? = nil) async -> SyncResult? {
        let appearance = appearance ?? config.appearance()
        lastSync = .now
        var options = AgentClient.Options(capabilities: [AgentHandshake.Capability.core, AgentHandshake.Capability.system])
        options.helloTimeout = config.helloTimeout
        guard FileManager.default.fileExists(atPath: config.socket.path(percentEncoded: false)),
              let client = try? await AgentClient.connect(socket: config.socket, options: options, connectTimeout: .seconds(1)) else {
            failures += 1
            if failures == 1 { log("agent link: no agent answering (yet)") }
            return nil
        }
        if failures > 0 { log("agent link: agent answering") }
        failures = 0
        defer { Task { await client.close() } }
        let negotiated = await client.negotiated
        var result = SyncResult(agentBuild: negotiated?.peerBuild ?? "", session: nil, timeSynced: false, appearanceSent: nil)
        guard negotiated?.capabilities.contains(AgentHandshake.Capability.system) == true else {
            return result // an agent without the system family (WP4.2): nothing to do
        }

        // The service sends SessionState right after its Hello reply.
        result.session = await Self.firstSessionState(client.events, within: .milliseconds(1500))

        var time = Seemless_V1_TimeSync()
        time.unixNanos = Int64((config.now().timeIntervalSince1970 * 1e9).rounded())
        if config.sendTime, (try? await client.request(.timeSync(time))) != nil { result.timeSynced = true }

        var info = Seemless_V1_SetHostInfo()
        info.appearance = appearance.proto
        if config.sendHostInfo, (try? await client.request(.setHostInfo(info))) != nil {
            result.appearanceSent = appearance
            if appearance != lastAppearance { log("agent link: Windows appearance → \(appearance)") }
            lastAppearance = appearance
        }

        if let s = result.session, s != lastSession {
            lastSession = s
            log("agent link: session logged_on=\(s.loggedOn) locked=\(s.locked) user=\(AgentLink.printable(s.user))")
        }
        if config.finishSetupWhenSignedIn, let s = result.session, Self.isSignedInDesktop(s) {
            config.finishSetupWhenSignedIn = false
            log("agent link: Windows reached a signed-in desktop; ending the offline first setup")
            await onSignedInDesktop()
        }
        return result
    }

    static func firstSessionState(_ events: AsyncStream<Seemless_V1_Envelope>, within: Duration) async -> Seemless_V1_SessionState? {
        await withTaskGroup(of: Seemless_V1_SessionState?.self) { group in
            group.addTask {
                for await env in events {
                    if case .sessionState(let s) = env.body { return s }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: within)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Guest text for a log line: printable, at most 64 characters.
    public static func printable(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64)).debugDescription
    }

    /// Asks the agent to shut Windows down (or restart / sign out). True
    /// once the agent acknowledged; false when no agent with the system
    /// family answered within `timeout`.
    public static func requestShutdown(socket: URL, mode: Seemless_V1_Shutdown.Mode = .shutdown,
                                       timeout: Duration = .seconds(3)) async -> Bool {
        guard FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)) else { return false }
        var options = AgentClient.Options(capabilities: [AgentHandshake.Capability.core, AgentHandshake.Capability.system])
        options.helloTimeout = timeout
        guard let client = try? await AgentClient.connect(socket: socket, options: options, connectTimeout: .seconds(1)) else { return false }
        defer { Task { await client.close() } }
        guard await client.negotiated?.capabilities.contains(AgentHandshake.Capability.system) == true else { return false }
        var request = Seemless_V1_Shutdown()
        request.mode = mode
        guard let reply = try? await client.request(.shutdown(request), timeout: timeout), case .ack = reply.body else { return false }
        return true
    }
}
