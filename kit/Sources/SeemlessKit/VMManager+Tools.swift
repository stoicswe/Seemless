import Foundation

/// Guest tools updates in a running VM (docs/06 "Guest tools ISO", WP4.3).
extension VMManager {
    public struct ToolsUpdate: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable { case upToDate, updated }
        public var outcome: Outcome
        /// Versions before and after ("0.0.2 (8bc3fb59e430)").
        public var before: String
        public var after: String
    }

    public enum ToolsError: Error, Equatable, CustomStringConvertible {
        case noISO(String), badVersion(String), didNotReturn(String, String)

        public var description: String {
            switch self {
            case .noISO(let p): return "no tools ISO at \(p) (build it with guest/tools/build.sh)"
            case .badVersion(let p): return "\(p) holds no valid tools version"
            case .didNotReturn(let want, let last):
                return "the agent did not come back as \(want) in time (last seen: \(last.isEmpty ? "none" : last)); see %ProgramData%\\Seemless\\logs\\tools-update.log in the guest"
            }
        }
    }

    /// The version of the agent answering in VM `name` (from its Hello).
    public func installedToolsVersion(_ name: String, timeout: Duration = .seconds(10)) async throws -> String {
        let client = try await agentClient(name, helloTimeout: timeout)
        defer { Task { await client.close() } }
        return GuestTools.version(fromBuild: await client.negotiated?.peerBuild ?? "")
    }

    /// Updates the agent in the running VM from `tools`' ISO: hot-plugs it as
    /// a CD, sends `UpdateTools`, waits until the agent says Hello with the
    /// new version, then unplugs the CD. Does nothing when the versions match,
    /// unless `force`.
    public func updateTools(_ name: String, tools: GuestTools, force: Bool = false,
                            returnTimeout: Duration = .seconds(180),
                            log: @Sendable (String) -> Void = { _ in }) async throws -> ToolsUpdate {
        guard try store.load(name).allows(.agent) else { throw ManagerError.quarantined(name, .agent) }
        guard tools.hasISO else { throw ToolsError.noISO(tools.iso.path(percentEncoded: false)) }
        guard let target = tools.version else { throw ToolsError.badVersion(tools.agentDirectory.appending(path: "version.txt").path(percentEncoded: false)) }

        let before = try await installedToolsVersion(name)
        log("installed: \(before)")
        log("tools ISO: \(target)")
        if before == target && !force { return ToolsUpdate(outcome: .upToDate, before: before, after: before) }

        try await withQMP(name) { qmp in try await GuestTools.attach(iso: tools.iso, qmp: qmp) }
        log("tools CD attached (volume \(GuestTools.volumeLabel))")
        do {
            let after = try await requestUpdate(name, target: target, returnTimeout: returnTimeout, log: log)
            try? await withQMP(name) { qmp in await GuestTools.detach(qmp: qmp) }
            log("tools CD removed")
            return ToolsUpdate(outcome: .updated, before: before, after: after)
        } catch {
            try? await withQMP(name) { qmp in await GuestTools.detach(qmp: qmp) }
            throw error
        }
    }

    private func requestUpdate(_ name: String, target: String, returnTimeout: Duration,
                               log: @Sendable (String) -> Void) async throws -> String {
        var request = Seemless_V1_UpdateTools()
        request.isoVolumeLabel = GuestTools.volumeLabel
        request.version = target
        // Windows mounts a hot-plugged CD within a few seconds; until then the
        // agent answers "no volume labelled ...". Retry that for a while.
        let mountDeadline = ContinuousClock.now + .seconds(30)
        while true {
            let client = try await agentClient(name, helloTimeout: .seconds(10))
            do {
                let reply = try await client.request(.updateTools(request), timeout: .seconds(15))
                await client.close()
                guard case .ack = reply.body else {
                    throw AgentError.unexpectedReply(expected: "Ack", got: reply.body.map { "\($0)" } ?? "")
                }
                break
            } catch AgentError.remote(let code, let message) where message.hasPrefix("no volume labelled") && ContinuousClock.now < mountDeadline {
                await client.close()
                // Guest text: printable characters only before it reaches a terminal.
                let shown = String(message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
                log("waiting for Windows to mount the CD (\(code): \(shown))")
                try await Task.sleep(for: .seconds(2))
            } catch {
                await client.close()
                throw error
            }
        }
        log("update started in the guest; waiting for the agent to come back")

        // install.cmd stops the service, swaps the files and starts it again.
        let deadline = ContinuousClock.now + returnTimeout
        var last = ""
        try await Task.sleep(for: .seconds(3))
        while ContinuousClock.now < deadline {
            if let client = try? await agentClient(name, helloTimeout: .seconds(3)) {
                last = GuestTools.version(fromBuild: await client.negotiated?.peerBuild ?? "")
                await client.close()
                if last == target { return last }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ToolsError.didNotReturn(target, last)
    }

    /// A fresh agent connection to VM `name` (core capabilities only).
    func agentClient(_ name: String, helloTimeout: Duration) async throws -> AgentClient {
        guard try store.load(name).allows(.agent) else { throw ManagerError.quarantined(name, .agent) }
        guard let remote = VMRemote.attach(store.files(for: name)) else { throw ManagerError.notRunning(name) }
        var options = AgentClient.Options()
        options.helloTimeout = helloTimeout
        return try await AgentClient.connect(socket: remote.record.run.agentSocket, options: options, connectTimeout: .seconds(2))
    }
}

/// System messages for running VMs (docs/06 "System", WP4.4).
extension VMManager {
    /// Starts the agent link of an owned VM (clock, appearance, end of the
    /// offline first setup). A quarantined VM with its agent connection off
    /// gets none.
    func startAgentLink(_ name: String, config: VMConfig, run: RunPaths, vm: VMProcess) {
        links[name]?.task.cancel()
        links[name] = nil
        guard config.allows(.agent) else { return }
        var c = AgentLink.Configuration(socket: run.agentSocket, finishSetupWhenSignedIn: config.offlineUntilSetupDone)
        c.keepRunning = { [weak vm] in
            guard let vm else { return false }
            switch await vm.state {
            case .stopped, .crashed: return false
            default: return true
            }
        }
        let link = AgentLink(c) { line in FileHandle.standardError.write(Data("[\(name)] \(line)\n".utf8)) } onSignedInDesktop: { [weak self] in
            do { try await self?.finishOfflineSetup(name) } catch {
                FileHandle.standardError.write(Data("[\(name)] ending the offline setup failed: \(error)\n".utf8))
            }
        }
        links[name] = (link, Task { await link.run() })
    }

    /// Asks Windows to shut down through the agent. False when the VM has
    /// no agent (none installed, quarantine, an agent without system.v1) or
    /// it did not answer; callers then use the ACPI power button.
    public func askAgentToShutDown(_ name: String, mode: Seemless_V1_Shutdown.Mode = .shutdown) async -> Bool {
        guard let config = try? store.load(name), config.allows(.agent),
              let remote = VMRemote.attach(store.files(for: name)) else { return false }
        return await AgentLink.requestShutdown(socket: remote.record.run.agentSocket, mode: mode)
    }
}
