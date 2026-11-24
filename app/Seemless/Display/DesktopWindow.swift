import AppKit
import Carbon.HIToolbox
import Metal
import QuartzCore
import SeemlessKit

/// Desktop mode (WP3.2): the whole guest screen (scanout 0) in one ordinary
/// Mac window, for a VM started with an exported display.
///
/// - Keys go through `KeyboardTranslator` (docs/07: Mac or PC style, macOS
///   shortcuts reserved), the pointer is absolute, both over QMP
///   `input-send-event` as in Zen mode.
/// - Resizing the window, entering full screen or moving to a screen with
///   another scale asks the guest for a matching resolution
///   (`DisplayClient.requestSize`, with the physical size for its EDID).
///   A resolution Windows picks itself reshapes the window instead.
/// - `DisplayPreferences` (per VM) choose standard or Retina scaling and
///   the keyboard style.
///
/// Not yet: the guest pointer shape (viogpu3d draws its own pointer into
/// the screen, so the Mac pointer is shown on top of it).
@MainActor
final class DesktopSession: NSObject, NSWindowDelegate {
    let vm: String
    private let files: VMFiles
    private let display: DisplayClient
    private let qmp: QMPClient
    private let renderer: ZenRenderer
    private var geometry: DesktopGeometry
    let window: NSWindow
    private let view: DesktopView
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []
    private var keyUpMonitor: Any?
    private enum InputOp { case events([GuestInputEvent]), releaseAll }
    private let sendInput: AsyncStream<InputOp>.Continuation
    private var scrollAccumulator = ScrollAccumulator()
    private var translator: KeyboardTranslator
    private(set) var preferences: DisplayPreferences
    /// SEEMLESS_DISPLAY_SCALE: Mac points per guest pixel, overriding the preference.
    private let scaleOverride: CGFloat?
    /// The size last asked of the guest; a scanout of (about) this size is
    /// our answer, anything else is the guest's own choice.
    private var lastRequest: (width: Int, height: Int)?
    private var resizeDebounce: Task<Void, Never>?
    private var notice: NSTitlebarAccessoryViewController?
    private var stopped = false
    /// Called once when the session ends (window closed or VM stopped); not after `stop()`.
    var onEnd: ((DesktopSession) -> Void)?
    /// Called when the person dismisses the licence notice.
    var onNoticeDismissed: ((DesktopSession) -> Void)?
    /// Finishes once `stop()` has closed the QMP connection (handover to Zen).
    private(set) var closed: Task<Void, Never>?

    /// Connects to a running VM's exported display. Throws
    /// `DisplayError.notExported` when the VM has QEMU's own window instead.
    static func start(vm: String, run: RunPaths, files: VMFiles, scaleOverride: CGFloat? = nil) async throws -> DesktopSession {
        let display = try DisplayClient(run: run)
        // The size comes with the surface ring QEMU announces on connect; a
        // still screen sends no frame, so do not wait for one (as Zen).
        var geometry: DesktopGeometry?
        for _ in 0..<100 {
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
        return DesktopSession(vm: vm, files: files, display: display, qmp: qmp, renderer: renderer,
                              geometry: geometry, scaleOverride: scaleOverride)
    }

    private init(vm: String, files: VMFiles, display: DisplayClient, qmp: QMPClient, renderer: ZenRenderer,
                 geometry: DesktopGeometry, scaleOverride: CGFloat?) {
        self.vm = vm
        self.files = files
        self.display = display
        self.qmp = qmp
        self.renderer = renderer
        self.geometry = geometry
        self.scaleOverride = scaleOverride
        let prefs = DisplayPreferences.load(files)
        preferences = prefs
        translator = KeyboardTranslator(style: prefs.keyboard)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let ppp = scaleOverride.map { 1 / $0 } ?? prefs.scaling.pixelsPerPoint(backingScale: screen?.backingScaleFactor ?? 2)
        let size = geometry.initialContentSize(pointsPerPixel: 1 / ppp,
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
        window.subtitle = "\(geometry.guestWidth) × \(geometry.guestHeight)"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.delegate = self
        applySizeRules()
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
        // AppKit does not deliver key-ups to the window while Command is
        // held; catch them here so Cmd shortcuts release in the guest.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] e in
            let code = e.keyCode, command = e.modifierFlags.contains(.command), number = e.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, command, number == self.window.windowNumber,
                      self.window.firstResponder === self.view else { return false }
                self.keyUp(code: code)
                return true
            }
            return handled ? nil : e
        }
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        // A window restored to another size asks the guest to match it.
        requestGuestSize()
    }

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    func toggleFullScreen() { window.toggleFullScreen(nil) }

    // MARK: Preferences

    /// Guest pixels per Mac point for this window's screen.
    private var pixelsPerPoint: CGFloat {
        scaleOverride.map { 1 / $0 } ?? preferences.scaling.pixelsPerPoint(backingScale: window.backingScaleFactor)
    }

    func update(_ prefs: DisplayPreferences) {
        guard prefs != preferences else { return }
        let scalingChanged = prefs.scaling != preferences.scaling
        preferences = prefs
        try? prefs.save(files)
        translator = KeyboardTranslator(style: prefs.keyboard)
        sendInput.yield(.releaseAll)
        applySizeRules()
        if scalingChanged, !isFullScreen {
            // Same guest resolution, new size on the Mac; then ask again.
            followGuestSize()
        }
        requestGuestSize()
    }

    /// Free resize when the guest follows the window; otherwise the
    /// window keeps the guest's aspect ratio and scales it.
    private func applySizeRules() {
        let ppp = pixelsPerPoint
        if preferences.resizeGuest {
            window.resizeIncrements = CGSize(width: 1, height: 1)
            window.contentMinSize = CGSize(width: CGFloat(DisplayResize.minimum.width) / ppp,
                                           height: CGFloat(DisplayResize.minimum.height) / ppp)
        } else {
            window.contentAspectRatio = geometry.aspectRatio
            window.contentMinSize = CGSize(width: 320, height: 320 * geometry.aspectRatio.height / geometry.aspectRatio.width)
        }
    }

    // MARK: Guest resolution

    /// Asks the guest for the resolution that fills the window at the
    /// current scaling. No-op when it already has it.
    func requestGuestSize() {
        guard preferences.resizeGuest, !stopped else { return }
        let content = view.bounds.size
        guard content.width > 0, content.height > 0 else { return }
        let size = DisplayResize.guestSize(forContent: content, pixelsPerPoint: pixelsPerPoint)
        if size.width == geometry.guestWidth, size.height == geometry.guestHeight { lastRequest = size; return }
        if let last = lastRequest, last == size { return }
        var mm = (width: 0, height: 0)
        if let screen = window.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            mm = DisplayResize.physicalSize(forContent: content, screenPoints: screen.frame.size,
                                            screenMillimetres: CGDisplayScreenSize(id))
        }
        do {
            try display.requestSize(width: size.width, height: size.height, widthMM: mm.width, heightMM: mm.height)
            lastRequest = size
            if ProcessInfo.processInfo.environment["SEEMLESS_DISPLAY_LOG"] != nil {
                NSLog("Seemless display %@: requested %dx%d (%dx%d mm)", vm, size.width, size.height, mm.width, mm.height)
            }
        } catch {
            NSLog("Seemless display %@: size request failed: %@", vm, String(describing: error))
        }
    }

    private func scheduleGuestSize() {
        resizeDebounce?.cancel()
        resizeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.requestGuestSize()
        }
    }

    /// Developer switch (SEEMLESS_DISPLAY_RESIZE=WxH): sets the content size
    /// in points and then does what the end of a live resize does.
    func resizeForTesting(points: CGSize) {
        let current = window.contentRect(forFrameRect: window.frame)
        let frame = window.frameRect(forContentRect: CGRect(x: current.minX, y: current.maxY - points.height,
                                                            width: points.width, height: points.height))
        window.setFrame(frame, display: true, animate: false)
        resizeDebounce?.cancel()
        requestGuestSize()
    }

    /// Polled: the guest's resolution changed.
    private func checkDisplaySize() {
        guard let s = display.scanout(), geometry.update(guestWidth: s.width, guestHeight: s.height) else { return }
        view.geometry = geometry
        window.subtitle = "\(s.width) × \(s.height)"
        if !preferences.resizeGuest {
            window.contentAspectRatio = geometry.aspectRatio
            window.contentMinSize = CGSize(width: 320, height: 320 * geometry.aspectRatio.height / geometry.aspectRatio.width)
            guard !isFullScreen else { return }
            let visible = window.screen?.visibleFrame ?? .zero
            let current = window.contentRect(forFrameRect: window.frame)
            setContentSize(geometry.contentSize(resizing: current.size, fitting: visible.size))
            return
        }
        // Our own request answered: the window already has this size.
        if DisplayResize.isAnswer(guestWidth: s.width, guestHeight: s.height, to: lastRequest) { return }
        // Windows chose a resolution itself (Settings ▸ Display, a game):
        // the window follows it, and this size counts as asked for.
        lastRequest = (s.width, s.height)
        guard !isFullScreen else { return }
        followGuestSize()
    }

    /// Window content = the guest screen at the current scaling, shrunk to fit.
    private func followGuestSize() {
        let visible = window.screen?.visibleFrame ?? .zero
        setContentSize(geometry.initialContentSize(pointsPerPixel: 1 / pixelsPerPoint, fitting: visible.size))
    }

    /// Keeps the top-left corner where it is.
    private func setContentSize(_ size: CGSize) {
        let visible = window.screen?.visibleFrame ?? .zero
        let current = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: CGRect(x: current.minX, y: current.maxY - size.height,
                                                            width: size.width, height: size.height))
        if !visible.isEmpty { frame.origin.y = max(frame.origin.y, visible.minY) }
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: Licence notice

    /// A bar under the title: the person reads and accepts Microsoft's
    /// licence in Windows; Seemless never accepts it for them.
    func showLicenceNotice() {
        guard notice == nil else { return }
        let label = NSTextField(wrappingLabelWithString:
            "Windows will show Microsoft’s licence terms. Read them and accept them yourself in this window: Seemless never accepts them for you. After that, Windows signs in to your account.")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
        let ok = NSButton(title: "OK", target: self, action: #selector(dismissLicenceNotice))
        ok.controlSize = .small
        ok.bezelStyle = .push
        let stack = NSStackView(views: [icon, label, ok])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.frame = CGRect(x: 0, y: 0, width: 600, height: 44)
        let vc = NSTitlebarAccessoryViewController()
        vc.view = stack
        vc.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(vc)
        notice = vc
    }

    @objc private func dismissLicenceNotice() {
        guard let notice, let i = window.titlebarAccessoryViewControllers.firstIndex(of: notice) else { return }
        window.removeTitlebarAccessoryViewController(at: i)
        self.notice = nil
        onNoticeDismissed?(self)
    }

    var hasLicenceNotice: Bool { notice != nil }

    // MARK: Window

    func windowWillClose(_ notification: Notification) { end() }
    func windowDidResignKey(_ notification: Notification) { lostFocus() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) { view.render(force: true) }
    }
    func windowDidResize(_ notification: Notification) {
        guard !window.inLiveResize else { return }
        scheduleGuestSize()            // zoom button, tiling, programmatic
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        resizeDebounce?.cancel()
        requestGuestSize()
    }
    func windowDidEnterFullScreen(_ notification: Notification) { requestGuestSize() }
    func windowDidExitFullScreen(_ notification: Notification) { requestGuestSize() }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        applySizeRules()
        requestGuestSize()
    }

    /// Closes the window and the connections; the VM keeps running. Safe to call twice.
    func stop() {
        guard !stopped else { return }
        stopped = true
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let m = keyUpMonitor { NSEvent.removeMonitor(m) }
        keyUpMonitor = nil
        resizeDebounce?.cancel()
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

    func keyDown(code: UInt16) { enqueue(translator.keyDown(keyCode: Int(code))) }
    func keyUp(code: UInt16) { enqueue(translator.keyUp(keyCode: Int(code))) }

    func modifiers(code: UInt16, flags: NSEvent.ModifierFlags) {
        enqueue(translator.flagsChanged(keyCode: Int(code), flags: flags.rawValue))
    }

    /// Cmd shortcuts: macOS's own (Cmd-Q, Cmd-H, …) go to the menus; the
    /// rest go to the guest. True when the guest took it.
    func keyEquivalent(_ e: NSEvent) -> Bool {
        if KeyboardTranslator.isReservedForMac(keyCode: Int(e.keyCode), flags: e.modifierFlags.rawValue) {
            translator.noteReservedShortcut()
            return false
        }
        if !e.isARepeat { keyDown(code: e.keyCode) }
        return true
    }

    func send(_ combo: GuestKeyCombo) {
        sendInput.yield(.releaseAll)
        translator.reset()
        enqueue(combo.events)
    }

    /// Keys held in the guest are released when the Mac focus leaves, so none sticks.
    func lostFocus() {
        guard !stopped else { return }
        translator.reset()
        sendInput.yield(.releaseAll)
    }

    // MARK: Developer switches (checks without UI automation)

    /// SEEMLESS_DISPLAY_TYPE: types `script` by sending key events through
    /// the window as the keyboard would (window → first responder or key
    /// equivalent → translator → QMP). Plain characters: lowercase letters,
    /// digits, space, `.`, `-`, newline. Braces hold keys and chords:
    /// `{cmd}` (a lone Command tap), `{cmd+a}`, `{shift+h}`, `{ret}`,
    /// `{esc}`, `{tab}`, `{bksp}`, `{wait}` (one second).
    func typeForTesting(_ script: String) async {
        var tokens: [String] = []
        var i = script.startIndex
        while i < script.endIndex {
            if script[i] == "{", let close = script[i...].firstIndex(of: "}") {
                tokens.append(String(script[script.index(after: i)..<close]))
                i = script.index(after: close)
            } else {
                tokens.append(String(script[i]))
                i = script.index(after: i)
            }
        }
        for t in tokens {
            if t == "wait" { try? await Task.sleep(for: .seconds(1)); continue }
            if t.count == 1 || ["ret", "esc", "tab", "bksp"].contains(t) {
                await press(t, modifiers: [])
                continue
            }
            let parts = t.split(separator: "+").map(String.init)
            var mods: [String] = Array(parts.dropLast())
            var last = parts.last ?? ""
            if parts.count == 1, ["cmd", "shift", "ctrl", "opt"].contains(last) { mods = [last]; last = "" }
            await chord(mods, key: last)
        }
    }

    private static let testKeyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "f": kVK_ANSI_F, "h": kVK_ANSI_H, "g": kVK_ANSI_G,
        "z": kVK_ANSI_Z, "x": kVK_ANSI_X, "c": kVK_ANSI_C, "v": kVK_ANSI_V, "b": kVK_ANSI_B, "q": kVK_ANSI_Q,
        "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "y": kVK_ANSI_Y, "t": kVK_ANSI_T, "o": kVK_ANSI_O,
        "u": kVK_ANSI_U, "i": kVK_ANSI_I, "p": kVK_ANSI_P, "l": kVK_ANSI_L, "j": kVK_ANSI_J, "k": kVK_ANSI_K,
        "n": kVK_ANSI_N, "m": kVK_ANSI_M,
        "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "0": kVK_ANSI_0,
        " ": kVK_Space, "\n": kVK_Return, "ret": kVK_Return, "esc": kVK_Escape, "tab": kVK_Tab,
        "bksp": kVK_Delete, ".": kVK_ANSI_Period, "-": kVK_ANSI_Minus,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
    ]

    private static let testModifiers: [String: (code: Int, flags: NSEvent.ModifierFlags, device: UInt)] = [
        "cmd": (kVK_Command, .command, 0x0008), "shift": (kVK_Shift, .shift, 0x0002),
        "ctrl": (kVK_Control, .control, 0x0001), "opt": (kVK_Option, .option, 0x0020),
    ]

    private func chord(_ mods: [String], key: String) async {
        var flags: NSEvent.ModifierFlags = []
        var device: UInt = 0
        for m in mods {
            guard let mod = Self.testModifiers[m] else { continue }
            flags.insert(mod.flags); device |= mod.device
            sendFlags(code: mod.code, flags: NSEvent.ModifierFlags(rawValue: flags.rawValue | device))
            try? await Task.sleep(for: .milliseconds(40))
        }
        if !key.isEmpty { await press(key, modifiers: NSEvent.ModifierFlags(rawValue: flags.rawValue | device)) }
        for m in mods.reversed() {
            guard let mod = Self.testModifiers[m] else { continue }
            flags.remove(mod.flags); device &= ~mod.device
            sendFlags(code: mod.code, flags: NSEvent.ModifierFlags(rawValue: flags.rawValue | device))
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func sendFlags(code: Int, flags: NSEvent.ModifierFlags) {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else { return }
        cg.type = .flagsChanged
        cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        guard let e = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(e)
    }

    private func press(_ key: String, modifiers: NSEvent.ModifierFlags) async {
        guard let code = Self.testKeyCodes[key] else { return }
        let ch = key.count == 1 ? key : ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: ch, charactersIgnoringModifiers: ch,
                                           isARepeat: false, keyCode: UInt16(code)) else { continue }
            // As AppKit does: Command keys are offered as key equivalents first.
            if type == .keyDown, modifiers.contains(.command) {
                if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
            } else {
                window.sendEvent(e)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
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
    override func keyDown(with e: NSEvent) { if !e.isARepeat { input?.keyDown(code: e.keyCode) } }
    override func keyUp(with e: NSEvent) { input?.keyUp(code: e.keyCode) }
    override func flagsChanged(with e: NSEvent) { input?.modifiers(code: e.keyCode, flags: e.modifierFlags) }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.modifierFlags.contains(.command), window?.firstResponder === self,
              let input else { return super.performKeyEquivalent(with: e) }
        return input.keyEquivalent(e) || super.performKeyEquivalent(with: e)
    }
    override func resignFirstResponder() -> Bool { input?.lostFocus(); return true }
}
