import AppKit
import SeemlessKit

/// One VM in Zen mode (docs/05, step Z1): the agent's window list becomes
/// chrome-less Mac windows, each showing its crop of scanout 0 (tier 2),
/// with pointer and keys sent to the guest over QMP.
///
/// Z1 limits (docs/05 "Readiness and build order"): overlapping guest
/// windows bleed into each other's crops until the atlas (Z4); focus,
/// cursor shapes and the clipboard need the real agent (Z3, Z3b).
@MainActor
final class ZenSession: NSObject, ZenInputSink, ZenWindowBehavior, NSWindowDelegate {
    let vm: String
    private let display: DisplayClient
    private let agent: AgentClient
    private let qmp: QMPClient
    private let input: GuestInput
    private let renderer: ZenRenderer
    private var model: ZenWindowModel
    private var geometry: ZenGeometry
    private var windows: [UInt64: ZenWindow] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []
    /// Input in order. Releasing held keys goes through the same queue, so it
    /// can never overtake a key-down that is still waiting to be sent.
    private enum InputOp { case events([GuestInputEvent]), releaseAll }
    private let sendInput: AsyncStream<InputOp>.Continuation
    /// Called once when the session ends by itself (agent gone or silent, VM
    /// stopped), with the reason to show (nil: nothing to report); not after `stop()`.
    var onEnd: ((ZenSession, String?) -> Void)?
    private var stopped = false
    /// Last hover hit test per window: the guest point it was taken at and
    /// the answer. A mouse-down uses it synchronously (docs/05, host-driven move).
    private var lastHit: [UInt64: (point: CGPoint, area: ZenHitArea)] = [:]
    /// Paces hover hit tests per window (docs/testing/seamless.md: 1,500 a minute unthrottled).
    private var hoverThrottle: [UInt64: HoverHitTestThrottle] = [:]
    private var hoverRetry: [UInt64: Task<Void, Never>] = [:]
    private var lastHover: [UInt64: CGPoint] = [:]
    private let clock = ContinuousClock()
    private let clockStart = ContinuousClock.now
    /// False once the agent cannot hit-test: clicks then all go to the guest.
    private var hitTestSupported = true
    /// Pending "tell the guest where the window is now", debounced while moving.
    private var pendingMoves: [UInt64: Task<Void, Never>] = [:]
    private var scrollAccumulator = ScrollAccumulator()
    private var resizePacer: [UInt64: LiveResizePacer] = [:]
    /// Counters for diagnostics and tests (`SEEMLESS_ZEN_STATS=1` logs them).
    private(set) var hitTestsSent = 0
    private(set) var setWindowRectsSent = 0
    private(set) var framesSeen = 0

    enum StartError: Error, CustomStringConvertible {
        case noMetal, noFrame
        var description: String {
            switch self {
            case .noMetal: "Metal is not available"
            case .noFrame: "the VM's display is not exported. Start it with “Start without Window” (exported display)."
            }
        }
    }

    /// Connects to a running VM. `agentSocket` is the VM's agent channel, or
    /// a `seemlessctl mock-agent` socket while the Windows agent does not exist.
    static func start(vm: String, run: RunPaths, agentSocket: URL, pointsPerPixel: CGFloat) async throws -> ZenSession {
        let display = try DisplayClient(run: run)
        // The display size comes with the surface ring QEMU announces on
        // connect. A still guest screen sends no frame until something
        // changes, so do not wait for one (testing: 6-15 s on a still desktop).
        var size: (width: Int, height: Int)?
        for _ in 0..<50 {
            if let f = display.latestFrame() { size = (f.width, f.height); break }
            if let sc = display.scanout(), sc.width > 0, sc.height > 0 { size = (sc.width, sc.height); break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let size else {
            display.close()
            throw StartError.noFrame
        }
        guard let renderer = ZenRenderer(display: display) else { display.close(); throw StartError.noMetal }
        // Zen holds its QMP connection for as long as it runs, so it uses its
        // own monitor; a VM started before input.sock existed only has ctl.sock.
        let qmpSocket = FileManager.default.fileExists(atPath: run.inputSocket.path(percentEncoded: false))
            ? run.inputSocket : run.controlSocket
        let qmp = try await QMPClient.connect(socket: qmpSocket, timeout: .seconds(5))
        let agent: AgentClient
        do {
            agent = try await AgentClient.connect(
                socket: agentSocket,
                options: AgentClient.Options(capabilities: [AgentHandshake.Capability.core, AgentHandshake.Capability.windows]),
                connectTimeout: .seconds(3))
        } catch {
            await qmp.close()
            display.close()
            throw error
        }
        let geometry = ZenGeometry(guestWidth: size.width, guestHeight: size.height,
                                   topLeft: guestTopLeft(), pointsPerPixel: pointsPerPixel)
        return ZenSession(vm: vm, display: display, agent: agent, qmp: qmp, renderer: renderer, geometry: geometry)
    }

    private init(vm: String, display: DisplayClient, agent: AgentClient, qmp: QMPClient,
                 renderer: ZenRenderer, geometry: ZenGeometry) {
        self.vm = vm
        self.display = display
        self.agent = agent
        self.qmp = qmp
        self.input = GuestInput(qmp: qmp)
        self.renderer = renderer
        self.geometry = geometry
        self.model = ZenWindowModel(bounds: GuestRect(x: 0, y: 0, width: geometry.guestWidth, height: geometry.guestHeight))
        let (stream, cont) = AsyncStream.makeStream(of: InputOp.self, bufferingPolicy: .bufferingNewest(512))
        sendInput = cont
        super.init()
        // One consumer keeps input in order.
        let input = self.input
        tasks.append(Task.detached {
            for await op in stream {
                switch op {
                case .events(let events): await input.send(events)
                case .releaseAll: await input.releaseAll()
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await envelope in agent.events {
                guard let body = envelope.body else { continue }
                self?.handle(body)
            }
            self?.end("The connection to the Windows agent closed.")
        })
        // docs/05 "Mode transitions": no heartbeat for 3 s means the agent is
        // lost. Windows would otherwise stay up, frozen, with nothing to drive them.
        tasks.append(Task { [weak self] in
            for await state in agent.states {
                switch state {
                case .unresponsive: self?.end("The Windows agent stopped responding.")
                case .peerRestarted: self?.agentRestarted()
                default: break
                }
            }
        })
        // QMP closes when QEMU exits: the VM stopped, so Zen ends with it.
        tasks.append(Task { [weak self] in
            for await _ in qmp.events {}
            self?.end(nil)          // the VM stopped: nothing to report
        })
        // Draw when QEMU delivers a frame: one loop for all windows, and
        // nothing at all while the guest screen is still.
        tasks.append(Task { [weak self] in
            var after: UInt64 = 0
            while !Task.isCancelled {
                do {
                    after = try await display.nextFrame(after: after, timeout: .seconds(1)).serial
                } catch DisplayError.closed {
                    return
                } catch {
                    continue                     // no new frame within the timeout
                }
                guard let self, !self.stopped else { return }
                self.framesSeen += 1
                self.drawAll()
            }
        })
        // The guest display can change size (resolution change, SET_SIZE).
        tasks.append(Task { [weak self] in
            let stats = ProcessInfo.processInfo.environment["SEEMLESS_ZEN_STATS"] == "1"
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.checkDisplaySize()
                ticks += 1
                if stats, ticks % 40 == 0 { self.logStats() }   // every 10 s
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFocus() }
        })
    }

    /// Guest pixel (0, 0) sits at the top-left of the primary screen's usable
    /// area (below the menu bar). The primary screen, not `NSScreen.main`,
    /// which follows the key window.
    private static func guestTopLeft() -> CGPoint {
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        return CGPoint(x: visible.minX, y: visible.maxY)
    }

    private func handle(_ body: Seemless_V1_Envelope.OneOf_Body) {
        guard !stopped else { return }
        apply(model.apply(body))
    }

    private func apply(_ changes: [ZenWindowModel.Change]) {
        for change in changes {
            switch change {
            case .added(let info), .updated(let info):
                // The window moved or changed under the pointer: the cached
                // hit test no longer describes what is there.
                if windows[info.id]?.info.rect != info.rect { lastHit[info.id] = nil }
                show(info)
            case .removed(let id):
                forget(id)
                if let w = windows.removeValue(forKey: id) { w.delegate = nil; w.close() }
            }
        }
    }

    private func forget(_ id: UInt64) {
        lastHit[id] = nil
        lastHover[id] = nil
        hoverThrottle[id] = nil
        hoverRetry.removeValue(forKey: id)?.cancel()
        pendingMoves.removeValue(forKey: id)?.cancel()
        resizePacer[id] = nil
    }

    private func agentRestarted() {
        // A new agent: it may hit-test now, and old answers are stale. Its
        // snapshot follows and replaces the window list (docs/06).
        hitTestSupported = true
        for id in Array(lastHit.keys) { lastHit[id] = nil }
        for id in Array(hoverThrottle.keys) { hoverThrottle[id] = nil }
    }

    private func checkDisplaySize() {
        guard !stopped, let s = display.scanout(), s.width > 0, s.height > 0,
              s.width != geometry.guestWidth || s.height != geometry.guestHeight else { return }
        geometry.guestWidth = s.width
        geometry.guestHeight = s.height
        // Windows outside the new display are no longer mirrored; the rest
        // get new crops (texture coordinates are relative to the display).
        apply(model.setBounds(GuestRect(x: 0, y: 0, width: s.width, height: s.height)))
        relayout()
    }

    private func screenChanged() {
        let tl = Self.guestTopLeft()
        guard !stopped, tl != geometry.topLeft else { return }
        geometry.topLeft = tl
        relayout()
    }

    /// Totals since the session started (`SEEMLESS_ZEN_STATS=1`: every 10 s and at the end).
    private func logStats() {
        NSLog("Zen %@: %d hit tests, %d SetWindowRect, %d frames, %d windows",
              vm, hitTestsSent, setWindowRectsSent, framesSeen, windows.count)
    }

    /// One command buffer per frame for all windows.
    private func drawAll() {
        guard let cb = renderer.queue.makeCommandBuffer() else { return }
        var any = false
        for w in windows.values where w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible) {
            if w.view.encode(into: cb) { any = true }
        }
        if any { cb.commit() }
    }

    /// Puts every window where the current geometry says.
    private func relayout() {
        for info in model.mirrored { windows[info.id]?.apply(info, geometry: geometry) }
    }

    private func show(_ info: ZenWindowInfo) {
        // Minimised in Windows → minimised in the Dock (not hidden), so the
        // user brings it back from there like any Mac window. That includes
        // windows that were already minimised when Zen started.
        if info.state == .minimized {
            guard !info.rect.isEmpty, info.kind == .normal || info.kind == .dialog || info.kind == .unspecified else { return }
            let w = window(for: info)
            w.apply(info, geometry: geometry)
            w.applyGuestMinimized(true)
            return
        }
        guard info.isMirrored else {
            windows[info.id]?.orderOut(nil)    // not an app window (or off-screen)
            return
        }
        let window = window(for: info)
        window.apply(info, geometry: geometry)
        if window.isMiniaturized { window.applyGuestMinimized(false) }
        if !window.isVisible { window.orderFront(nil) }
        attachToOwner(window)
    }

    private func window(for info: ZenWindowInfo) -> ZenWindow {
        if let w = windows[info.id] { return w }
        // An owned dialog opens where Windows puts it relative to its owner,
        // wherever the owner was moved to on the Mac.
        let offset = windows[info.ownerID]?.offset ?? .zero
        let w = ZenWindow(info: info, frame: geometry.macFrame(for: info.rect, offset: offset), renderer: renderer, input: self)
        w.offset = offset
        w.delegate = self
        w.behavior = self
        windows[info.id] = w
        return w
    }

    /// An owned dialog stays above its owner, as in Windows (docs/05 "Which
    /// windows are mirrored": child window of the owner's window).
    private func attachToOwner(_ window: ZenWindow) {
        let ownerID = window.info.ownerID
        guard ownerID != 0, let owner = windows[ownerID], owner.isVisible, !owner.isMiniaturized,
              window.parent !== owner else { return }
        owner.addChildWindow(window, ordered: .above)
    }

    // MARK: Window actions → guest (docs/05 "The Zen window")

    private func command(_ id: UInt64, _ cmd: Seemless_V1_WindowCommand.Command) {
        let agent = agent
        Task { _ = try? await agent.request(.windowCommand(.with { $0.id = id; $0.cmd = cmd })) }
    }

    /// Cmd-W: `WM_CLOSE`; the app may ask to save first. The Mac window
    /// closes when the agent reports the guest window gone.
    func requestClose(_ window: ZenWindow) { command(window.guestID, .close) }
    func requestMinimize(_ window: ZenWindow) { command(window.guestID, .minimize) }
    func requestToggleMaximize(_ window: ZenWindow) {
        command(window.guestID, window.info.state == .maximized ? .restore : .maximize)
    }

    /// The window was resized on the Mac: tell the guest the new size, so
    /// the app lays itself out again (the crop stretches until it reports).
    /// Moves are never sent: a Zen window moves on the Mac only (owner,
    /// 2026-11-24), and the guest window stays where Windows has it.
    private func sendSize(of window: ZenWindow) {
        let id = window.guestID
        pendingMoves[id]?.cancel()
        let agent = agent
        pendingMoves[id] = Task { [weak self] in
            guard !Task.isCancelled, let self, let window = self.windows[id] else { return }
            self.pendingMoves[id] = nil
            let info = window.info
            let s = self.geometry.pointsPerPixel
            // The edges' movement, applied to the full rectangle's size only
            // (a partly off-screen window keeps its real size).
            let dw = Int((window.frame.width / s).rounded()) - info.rect.width
            let dh = Int((window.frame.height / s).rounded()) - info.rect.height
            var rect = info.fullRect
            rect.width = max(1, rect.width + dw)
            rect.height = max(1, rect.height + dh)
            // Wholly inside the guest's work area, or the taskbar and other
            // windows show through; the guest window may move to fit, since
            // only the Mac position is the user's.
            rect = ZenGeometry.place(rect, in: self.geometry.assumedWorkArea)
            // The guest window's new top-left is where the Mac frame's top-left is now.
            window.offset = self.geometry.offset(placing: rect, at: window.frame)
            guard rect != info.fullRect else { return }
            self.setWindowRectsSent += 1
            _ = try? await agent.request(.setWindowRect(.with { $0.id = id; $0.rect = rect.protoRect }))
        }
    }

    /// Any Mac-side move (title-bar drag, snapping, Stage Manager) only
    /// changes where the window is shown: its offset from the guest position.
    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? ZenWindow, !w.applyingGuestFrame, !w.inLiveResize else { return }
        // A dialog moved along with its owner, which is following the guest:
        // it is put back by the owner (ZenWindow.followGuestFrame).
        if let owner = w.parent as? ZenWindow, owner.applyingGuestFrame { return }
        w.offset = geometry.offset(placing: w.info.rect, at: w.frame)
    }

    func windowDidResignKey(_ notification: Notification) { lostFocus() }

    /// A window that was covered missed frames (`drawAll` skips it): catch up.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? ZenWindow, w.occlusionState.contains(.visible) else { return }
        w.view.render()
    }

    /// During a live resize the guest window follows the edge (paced), so the
    /// app re-lays itself out as the user drags.
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? ZenWindow, w.inLiveResize, !stopped else { return }
        let id = w.guestID
        var pacer = resizePacer[id] ?? LiveResizePacer()
        let decision = pacer.sizeChanged(now: now)
        resizePacer[id] = pacer
        switch decision {
        case .sendNow: sendSize(of: w)
        case .alreadyScheduled: break
        case .sendAfter(let d):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(d))
                guard let self, let w = self.windows[id] else { return }
                self.resizePacer[id]?.scheduledSendRan(now: self.now)
                if w.inLiveResize { self.sendSize(of: w) }
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = notification.object as? ZenWindow else { return }
        resizePacer[w.guestID] = nil
        sendSize(of: w)
        // Snap to the size the guest really took (apps have minimum sizes),
        // once its answer has had time to arrive.
        let id = w.guestID
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let w = self.windows[id], !w.inLiveResize else { return }
            w.apply(w.info, geometry: self.geometry)
        }
    }

    // Minimise animations finish after the call returns, so "who started
    // it" is decided against the guest's last reported state, not a flag:
    // only a Mac-side change the guest has not made yet becomes a command.
    func windowDidDeminiaturize(_ notification: Notification) {
        guard let w = notification.object as? ZenWindow, w.info.state == .minimized else { return }
        command(w.guestID, .restore)           // restored from the Dock
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let w = notification.object as? ZenWindow, w.info.state != .minimized else { return }
        command(w.guestID, .minimize)          // minimised from the Mac side
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let w = sender as? ZenWindow { requestClose(w) }
        return false                           // the guest decides; WindowRemoved closes it
    }

    /// Closes every Zen window and connection. Safe to call more than once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if ProcessInfo.processInfo.environment["SEEMLESS_ZEN_STATS"] == "1" { logStats() }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        for t in pendingMoves.values { t.cancel() }
        for t in hoverRetry.values { t.cancel() }
        pendingMoves.removeAll()
        hoverRetry.removeAll()
        for w in windows.values { w.delegate = nil; w.close() }
        windows.removeAll()
        sendInput.yield(.releaseAll)      // after any queued key-downs
        sendInput.finish()
        for t in tasks.dropFirst() { t.cancel() }  // the input consumer drains, then ends
        let agent = agent, qmp = qmp, inputDone = tasks.first
        Task {
            await inputDone?.value
            await agent.close()
            await qmp.close()
        }
        display.close()
    }

    private func end(_ reason: String?) {
        guard !stopped else { return }
        stop()
        onEnd?(self, reason)
    }

    // MARK: ZenInputSink

    private func enqueue(_ events: [GuestInputEvent]) {
        guard !events.isEmpty else { return }
        sendInput.yield(.events(events))
    }

    /// The guest pixel under a Mac point of `window`, through its offset.
    private func guestPoint(_ p: CGPoint, in window: ZenWindow) -> CGPoint {
        geometry.guestPoint(fromMac: p, offset: window.offset)
    }

    private func absolute(_ p: CGPoint, in window: ZenWindow) -> GuestInputEvent {
        let a = geometry.absoluteAxes(guestPoint(p, in: window))
        return .absolute(x: a.x, y: a.y)
    }

    func pointer(atMac point: CGPoint, in window: ZenWindow, hover: Bool) {
        enqueue([absolute(point, in: window)])
        if hover { hoverHitTest(window, atMac: point) }
    }

    private var now: Double {
        let d = clock.now - clockStart
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Ask the guest what is under the pointer, so a mouse-down on the title
    /// bar can start a native drag without waiting. Paced by
    /// `HoverHitTestThrottle`: at most one request in flight per window, ten
    /// a second while moving, and one for the point where the pointer rests.
    private func hoverHitTest(_ window: ZenWindow, atMac point: CGPoint) {
        guard hitTestSupported, !stopped else { return }
        let id = window.guestID
        lastHover[id] = point
        var throttle = hoverThrottle[id] ?? HoverHitTestThrottle()
        let g = guestPoint(point, in: window)
        let decision = throttle.pointerMoved(to: g, now: now, cachedAt: lastHit[id]?.point)
        hoverThrottle[id] = throttle
        switch decision {
        case .skip:
            hoverRetry.removeValue(forKey: id)?.cancel()
        case .retry(let after):
            guard hoverRetry[id] == nil else { return }   // one retry pending is enough
            hoverRetry[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled, let self else { return }
                self.hoverRetry[id] = nil
                if let p = self.lastHover[id], let w = self.windows[id] { self.hoverHitTest(w, atMac: p) }
            }
        case .sendNow:
            hoverRetry.removeValue(forKey: id)?.cancel()
            hitTestsSent += 1
            let agent = agent
            Task { [weak self] in
                let reply: Seemless_V1_Envelope?
                do {
                    reply = try await agent.request(.hitTest(.with {
                        $0.id = id
                        $0.point = .with { $0.x = Int32(clamping: Int(g.x.rounded())); $0.y = Int32(clamping: Int(g.y.rounded())) }
                    }), timeout: .milliseconds(250))
                } catch AgentError.remote(.unsupported, _) {
                    reply = nil
                    self?.hitTestSupported = false     // this agent cannot hit-test
                } catch {
                    reply = nil
                }
                guard let self else { return }
                self.hoverThrottle[id]?.requestFinished()
                if case .hitTestResult(let r)? = reply?.body, self.windows[id] != nil {
                    self.lastHit[id] = (g, ZenHitArea(hitTestCode: r.code))
                }
            }
        }
    }

    func hitArea(atMac point: CGPoint, in window: ZenWindow) -> ZenHitArea {
        let g = guestPoint(point, in: window)
        // No agent hit test: assume a standard Windows 11 caption, so the
        // window can still be dragged on the Mac.
        guard hitTestSupported else { return .standardFrame(at: g, window: window.info.rect) }
        guard let last = lastHit[window.guestID] else { return .passThrough }
        // Only trust an answer taken close to where the button went down.
        guard HoverHitTestThrottle.trusts(last.point, for: g) else { return .passThrough }
        return last.area
    }

    func button(_ number: Int, down: Bool, atMac point: CGPoint, in window: ZenWindow) {
        guard let name = GuestInputEvent.buttonName(number) else { return }
        if down, ProcessInfo.processInfo.environment["SEEMLESS_ZEN_STATS"] == "1" {
            let g = guestPoint(point, in: window)
            NSLog("Zen %@: %@ button down at guest (%.1f, %.1f)", vm, name, g.x, g.y)
        }
        enqueue([absolute(point, in: window), .button(name, down: down)])
    }

    func scroll(deltaX: Double, deltaY: Double, precise: Bool, newGesture: Bool) {
        if newGesture { scrollAccumulator.reset() }
        let c = scrollAccumulator.clicks(deltaX: deltaX, deltaY: deltaY, precise: precise)
        enqueue(GuestInputEvent.wheel(clicksY: c.y, clicksX: c.x))
    }

    func key(code: UInt16, down: Bool) {
        guard let q = GuestKeyMap.qcode(forKeyCode: Int(code)) else { return }
        enqueue([.key(qcode: q, down: down)])
    }

    func modifiers(code: UInt16, flags: NSEvent.ModifierFlags) {
        enqueue(GuestKeyMap.modifierEvents(keyCode: Int(code), flags: flags.rawValue))
    }

    /// Keys held in the guest are released when the Mac focus leaves Zen
    /// (another app, another window), so no modifier sticks (docs/05).
    func lostFocus() {
        guard !stopped else { return }
        sendInput.yield(.releaseAll)
    }
}
