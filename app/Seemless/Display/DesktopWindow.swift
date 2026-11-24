import AppKit
import Metal
import QuartzCore
import SeemlessKit

/// The whole guest screen (scanout 0) in one ordinary Mac window, for a VM
/// started with an exported display (WP3.2, first part). Pointer and keys
/// go to the guest over QMP `input-send-event`, as in Zen mode.
///
/// Not yet: resizing the window does not change the guest resolution (it
/// scales, aspect kept); the guest pointer shape is not drawn (the Mac
/// pointer is the pointer).
@MainActor
final class DesktopSession: NSObject, NSWindowDelegate {
    let vm: String
    private let display: DisplayClient
    private let qmp: QMPClient
    private let renderer: ZenRenderer
    private var geometry: DesktopGeometry
    let window: NSWindow
    private let view: DesktopView
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []
    private enum InputOp { case events([GuestInputEvent]), releaseAll }
    private let sendInput: AsyncStream<InputOp>.Continuation
    private var scrollAccumulator = ScrollAccumulator()
    private var stopped = false
    /// Called once when the session ends (window closed or VM stopped); not after `stop()`.
    var onEnd: ((DesktopSession) -> Void)?
    /// Finishes once `stop()` has closed the QMP connection (handover to Zen).
    private(set) var closed: Task<Void, Never>?

    /// Connects to a running VM's exported display. Throws
    /// `DisplayError.notExported` when the VM has QEMU's own window instead.
    static func start(vm: String, run: RunPaths, pointsPerPixel: CGFloat = 1) async throws -> DesktopSession {
        let display = try DisplayClient(run: run)
        // The size comes with the surface ring QEMU announces on connect; a
        // still screen sends no frame, so do not wait for one (as Zen).
        var geometry: DesktopGeometry?
        for _ in 0..<50 {
            if let f = display.latestFrame() { geometry = DesktopGeometry(guestWidth: f.width, guestHeight: f.height) }
            if geometry == nil, let s = display.scanout() { geometry = DesktopGeometry(guestWidth: s.width, guestHeight: s.height) }
            if geometry != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let geometry else { display.close(); throw ZenSession.StartError.noFrame }
        guard let renderer = ZenRenderer(display: display) else { display.close(); throw ZenSession.StartError.noMetal }
        // Held while the window is open: its own monitor, as Zen (the two
        // are never open together, see AppModel).
        let qmpSocket = FileManager.default.fileExists(atPath: run.inputSocket.path(percentEncoded: false))
            ? run.inputSocket : run.controlSocket
        let qmp: QMPClient
        do {
            qmp = try await QMPClient.connect(socket: qmpSocket, timeout: .seconds(5))
        } catch {
            display.close()
            throw error
        }
        return DesktopSession(vm: vm, display: display, qmp: qmp, renderer: renderer,
                              geometry: geometry, pointsPerPixel: pointsPerPixel)
    }

    private init(vm: String, display: DisplayClient, qmp: QMPClient, renderer: ZenRenderer,
                 geometry: DesktopGeometry, pointsPerPixel: CGFloat) {
        self.vm = vm
        self.display = display
        self.qmp = qmp
        self.renderer = renderer
        self.geometry = geometry
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = geometry.initialContentSize(pointsPerPixel: pointsPerPixel,
                                               fitting: CGSize(width: visible.width * 0.9, height: visible.height * 0.9))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        view = DesktopView(renderer: renderer, geometry: geometry)
        let (stream, cont) = AsyncStream.makeStream(of: InputOp.self, bufferingPolicy: .bufferingNewest(512))
        sendInput = cont
        super.init()
        view.input = self
        window.title = vm
        window.subtitle = "Windows display"
        window.contentView = view
        window.contentAspectRatio = geometry.aspectRatio
        window.contentMinSize = CGSize(width: 320, height: 320 * geometry.aspectRatio.height / geometry.aspectRatio.width)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.setFrameAutosaveName("Seemless.Display.\(vm)")
        if window.frame.origin == .zero { window.center() }
        window.initialFirstResponder = view

        let input = GuestInput(qmp: qmp)
        tasks.append(Task.detached {          // one consumer keeps input in order
            for await op in stream {
                switch op {
                case .events(let e): await input.send(e)
                case .releaseAll: await input.releaseAll()
                }
            }
        })
        // QMP closes when QEMU exits: the VM stopped, the window closes.
        tasks.append(Task { [weak self] in
            for await _ in qmp.events {}
            self?.end()
        })
        tasks.append(Task { [weak self] in
            var after: UInt64 = 0
            while !Task.isCancelled {
                do {
                    after = try await display.nextFrame(after: after, timeout: .seconds(1)).serial
                } catch DisplayError.closed {
                    return
                } catch {
                    continue
                }
                guard let self, !self.stopped else { return }
                if self.window.occlusionState.contains(.visible) { self.view.render() }
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !self.stopped else { return }
                self.checkDisplaySize()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFocus() }
        })
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Developer switch for checks without UI automation (SEEMLESS_DISPLAY_TYPE):
    /// types `text` by sending key events through the window, as the keyboard
    /// would (window → first responder → QMP). Lowercase letters, digits,
    /// space and newline (Return) only.
    func typeForTesting(_ text: String) async {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
            "n": 45, "m": 46, " ": 49, "\n": 36,
        ]
        for ch in text {
            guard let code = codes[ch] else { continue }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: String(ch), charactersIgnoringModifiers: String(ch),
                                               isARepeat: false, keyCode: code) else { continue }
                window.sendEvent(e)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// The guest changed resolution: new ratio, same width (shrunk to fit the screen).
    private func checkDisplaySize() {
        guard let s = display.scanout(), geometry.update(guestWidth: s.width, guestHeight: s.height) else { return }
        view.geometry = geometry
        window.contentAspectRatio = geometry.aspectRatio
        window.contentMinSize = CGSize(width: 320, height: 320 * geometry.aspectRatio.height / geometry.aspectRatio.width)
        guard !window.styleMask.contains(.fullScreen) else { return }
        let visible = window.screen?.visibleFrame ?? .zero
        let current = window.contentRect(forFrameRect: window.frame)
        let size = geometry.contentSize(resizing: current.size, fitting: visible.size)
        // Keep the top-left corner where it is.
        var frame = window.frameRect(forContentRect: CGRect(x: current.minX, y: current.maxY - size.height,
                                                            width: size.width, height: size.height))
        if !visible.isEmpty { frame.origin.y = max(frame.origin.y, visible.minY) }
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) { end() }
    func windowDidResignKey(_ notification: Notification) { lostFocus() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) { view.render(force: true) }
    }

    /// Closes the window and the connections; the VM keeps running. Safe to call twice.
    func stop() {
        guard !stopped else { return }
        stopped = true
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        window.delegate = nil
        window.close()
        sendInput.yield(.releaseAll)
        sendInput.finish()
        for t in tasks.dropFirst() { t.cancel() }
        let qmp = qmp, inputDone = tasks.first
        closed = Task {
            await inputDone?.value
            await qmp.close()
        }
        display.close()
    }

    private func end() {
        guard !stopped else { return }
        stop()
        onEnd?(self)
    }

    // MARK: Input (from DesktopView, in view points, origin top-left)

    private func enqueue(_ events: [GuestInputEvent]) {
        guard !events.isEmpty, !stopped else { return }
        sendInput.yield(.events(events))
    }

    private func absolute(_ p: CGPoint) -> GuestInputEvent {
        let a = geometry.absoluteAxes(fromView: p, viewSize: view.bounds.size)
        return .absolute(x: a.x, y: a.y)
    }

    func pointer(at p: CGPoint) { enqueue([absolute(p)]) }

    func button(_ number: Int, down: Bool, at p: CGPoint) {
        guard let name = GuestInputEvent.buttonName(number) else { return }
        enqueue([absolute(p), .button(name, down: down)])
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

    /// Keys held in the guest are released when the Mac focus leaves, so none sticks.
    func lostFocus() {
        guard !stopped else { return }
        sendInput.yield(.releaseAll)
    }
}

/// Draws the whole scanout, aspect-fit, and forwards input to the session.
final class DesktopView: NSView {
    private let renderer: ZenRenderer
    weak var input: DesktopSession?
    var geometry: DesktopGeometry { didSet { if geometry != oldValue { render(force: true) } } }
    private var lastSerial: UInt64 = 0
    private var tracking: NSTrackingArea?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: ZenRenderer, geometry: DesktopGeometry) {
        self.renderer = renderer
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }   // view points match guest pixels: origin top-left

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer.device
        l.pixelFormat = .bgra8Unorm
        l.isOpaque = true
        l.displaySyncEnabled = true
        l.framebufferOnly = true
        return l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if tracking == nil {
            let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        render(force: true)
    }

    /// Draws the latest frame if it is new (or `force`).
    func render(force: Bool = false) {
        guard let window, let (texture, serial) = renderer.currentTexture() else { return }
        guard force || serial != lastSerial else { return }
        let fit = geometry.drawRect(in: bounds.size)
        guard fit.width > 0, fit.height > 0, let drawable = metalLayer.nextDrawable(),
              let cb = renderer.queue.makeCommandBuffer() else { return }
        lastSerial = serial
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let s = Double(window.backingScaleFactor)
        let tw = Double(drawable.texture.width), th = Double(drawable.texture.height)
        let x = min(Double(fit.minX) * s, tw), y = min(Double(fit.minY) * s, th)
        enc.setViewport(MTLViewport(originX: x, originY: y,
                                    width: min(Double(fit.width) * s, tw - x), height: min(Double(fit.height) * s, th - y),
                                    znear: 0, zfar: 1))
        enc.setRenderPipelineState(renderer.pipeline)
        enc.setFragmentTexture(texture, index: 0)
        var crop = SIMD4<Float>(0, 0, 1, 1)
        enc.setFragmentBytes(&crop, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) { input?.pointer(at: point(e)) }
    override func mouseDragged(with e: NSEvent) { input?.pointer(at: point(e)) }
    override func rightMouseDragged(with e: NSEvent) { input?.pointer(at: point(e)) }
    override func otherMouseDragged(with e: NSEvent) { input?.pointer(at: point(e)) }
    override func mouseDown(with e: NSEvent) { input?.button(0, down: true, at: point(e)) }
    override func mouseUp(with e: NSEvent) { input?.button(0, down: false, at: point(e)) }
    override func rightMouseDown(with e: NSEvent) { input?.button(1, down: true, at: point(e)) }
    override func rightMouseUp(with e: NSEvent) { input?.button(1, down: false, at: point(e)) }
    override func otherMouseDown(with e: NSEvent) { input?.button(e.buttonNumber, down: true, at: point(e)) }
    override func otherMouseUp(with e: NSEvent) { input?.button(e.buttonNumber, down: false, at: point(e)) }
    override func scrollWheel(with e: NSEvent) {
        input?.scroll(deltaX: e.scrollingDeltaX, deltaY: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
                      newGesture: e.phase == .began || e.phase == .mayBegin)
    }
    override func keyDown(with e: NSEvent) { if !e.isARepeat { input?.key(code: e.keyCode, down: true) } }
    override func keyUp(with e: NSEvent) { input?.key(code: e.keyCode, down: false) }
    override func flagsChanged(with e: NSEvent) { input?.modifiers(code: e.keyCode, flags: e.modifierFlags) }
    override func resignFirstResponder() -> Bool { input?.lostFocus(); return true }
}
