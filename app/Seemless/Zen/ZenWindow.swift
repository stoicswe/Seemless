import AppKit
import Metal
import QuartzCore
import SeemlessKit

/// One Windows top-level window shown as a chrome-less Mac window
/// (docs/05 "The Zen window"): no title bar, no traffic lights; the Windows
/// app's own frame and buttons are the window.
final class ZenWindow: NSWindow {
    /// macOS-style window corners (owner, 2026-11-24): the Mac look, not
    /// Windows 11's 8 px. Large enough to hide the guest's own rounded corners.
    static let cornerRadius: CGFloat = 16

    let guestID: UInt64
    let view: ZenCropView
    private(set) var info: ZenWindowInfo
    /// Set while the frame follows the guest, so our own move/resize
    /// notifications are not echoed back to it.
    private(set) var applyingGuestFrame = false
    weak var behavior: ZenWindowBehavior?
    /// Where the window is on the Mac relative to its guest position (Mac
    /// points). Moving the window on the Mac changes only this (owner,
    /// 2026-11-24); input is mapped back through it.
    var offset: CGVector = .zero

    init(info: ZenWindowInfo, frame: CGRect, renderer: ZenRenderer, input: ZenInputSink) {
        self.guestID = info.id
        self.info = info
        view = ZenCropView(renderer: renderer, input: input)
        // Borderless, but resizable and miniaturizable: macOS's own edge
        // resizing and Dock minimise apply. There is still no title bar and
        // no traffic lights; the Windows frame is the window (docs/05).
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        // A plain container rounds and clips: a Metal backing layer is not
        // clipped by its own corner radius when it is the window's top view.
        let container = ZenRoundedContainer(radius: Self.cornerRadius)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        contentView = container
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true                       // DWM's own shadow is never captured (docs/05)
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        isMovable = true                       // only performDrag moves it: there is no title bar to grab
        animationBehavior = .documentWindow
        minSize = CGSize(width: 160, height: 80)
    }

    // A borderless window cannot become key unless it says so.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func apply(_ info: ZenWindowInfo, geometry: ZenGeometry) {
        self.info = info
        title = info.title                     // Mission Control, Window menu, Dock
        if !inLiveResize, !view.isDragging { followGuestFrame(geometry) }
        view.contentSize = CGSize(width: CGFloat(info.rect.width) * geometry.pointsPerPixel,
                                  height: CGFloat(info.rect.height) * geometry.pointsPerPixel)
        view.textureRect = geometry.textureRect(for: info.rect)
        // No larger than the guest can show (its work area).
        let area = geometry.assumedWorkArea
        maxSize = CGSize(width: CGFloat(area.width) * geometry.pointsPerPixel, height: CGFloat(area.height) * geometry.pointsPerPixel)
        let wanted: NSWindow.Level = info.topmost ? .floating : .normal
        if level != wanted { level = wanted }
    }

    private func followGuestFrame(_ geometry: ZenGeometry) {
        let frame = geometry.macFrame(for: info.rect, offset: offset)
        guard frame != self.frame else { return }
        applyingGuestFrame = true
        setFrame(frame, display: true, animate: false)
        // AppKit moves child windows (owned dialogs) along with their parent,
        // but in Windows they stay where they are: put them back.
        for child in childWindows ?? [] { (child as? ZenWindow)?.followGuestFrame(geometry) }
        applyingGuestFrame = false
    }

    /// The guest minimised or restored the window: mirror it in the Dock.
    func applyGuestMinimized(_ minimized: Bool) {
        guard minimized != isMiniaturized else { return }
        minimized ? miniaturize(nil) : deminiaturize(nil)
    }

    // Cmd-W / File ▸ Close and Cmd-M act on the Windows app, which decides
    // (unsaved-changes prompts work). The Mac window follows the guest.
    override func performClose(_ sender: Any?) { behavior?.requestClose(self) }
    override func performMiniaturize(_ sender: Any?) { behavior?.requestMinimize(self) }
    override func performZoom(_ sender: Any?) { behavior?.requestToggleMaximize(self) }
}

/// Rounds and clips its content to macOS window corners.
final class ZenRoundedContainer: NSView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateShadow()  // the shadow follows the rounded shape
    }
}

/// Window actions the Mac side asks of the guest (docs/05 "The Zen window").
@MainActor
protocol ZenWindowBehavior: AnyObject {
    func requestClose(_ window: ZenWindow)
    func requestMinimize(_ window: ZenWindow)
    func requestToggleMaximize(_ window: ZenWindow)
}

/// Where a Zen window's input goes, already converted to guest terms.
@MainActor
protocol ZenInputSink: AnyObject {
    /// `hover`: a plain move (not a drag), which may ask the guest for a hit test.
    func pointer(atMac point: CGPoint, in window: ZenWindow, hover: Bool)
    func button(_ number: Int, down: Bool, atMac point: CGPoint, in window: ZenWindow)
    func scroll(deltaX: Double, deltaY: Double, precise: Bool, newGesture: Bool)
    func key(code: UInt16, down: Bool)
    func modifiers(code: UInt16, flags: NSEvent.ModifierFlags)
    func lostFocus()
    /// What a mouse-down here should do, from the last hit test (synchronous:
    /// the hover hit test ran while the pointer moved here).
    func hitArea(atMac point: CGPoint, in window: ZenWindow) -> ZenHitArea
}

/// Shared Metal state and the current scanout texture. All Zen windows
/// sample the same IOSurface (tier 2 crop, docs/05).
final class ZenRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private let display: DisplayClient
    /// Textures for the current surface ring only: a new ring (display
    /// resize) drops the old one, so its IOSurfaces are released.
    private var textures: [IOSurfaceID: MTLTexture] = [:]
    private var texturesGeneration: UInt32?

    init?(display: DisplayClient) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.display = display
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V vmain(uint i [[vertex_id]]) {
            float2 uv = float2((i << 1) & 2, i & 2);
            V v; v.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); v.uv = uv; return v;
        }
        // crop = (u, v, width, height) of this window in the scanout, 0...1.
        fragment float4 fmain(V v [[stage_in]], texture2d<float> t [[texture(0)]],
                              constant float4 &crop [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return float4(t.sample(s, crop.xy + v.uv * crop.zw).rgb, 1);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        pipeline = p
    }

    /// The latest scanout frame as a texture (cached per IOSurface of the ring).
    func currentTexture() -> (MTLTexture, UInt64)? {
        guard let frame = display.latestFrame() else { return nil }
        if frame.generation != texturesGeneration {
            textures.removeAll()
            texturesGeneration = frame.generation
        }
        let id = IOSurfaceGetID(frame.surface)
        if let t = textures[id], t.width == frame.width, t.height == frame.height { return (t, frame.serial) }
        let rgba = frame.fourcc == 0x5247_4241  // 'RGBA'
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: rgba ? .rgba8Unorm : .bgra8Unorm,
                                                         width: frame.width, height: frame.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d, iosurface: frame.surface, plane: 0) else { return nil }
        if textures.count > 8 { textures.removeAll() }  // a ring is a few surfaces; never grow unbounded
        textures[id] = t
        return (t, frame.serial)
    }
}

/// Draws one window's part of the scanout and forwards input. The Windows
/// pointer is never drawn: only the Mac pointer shows (docs/05 "Pointer");
/// virtio-gpu keeps the guest cursor out of the scanout.
///
/// There is no display link per window: the session draws every visible
/// window when QEMU delivers a frame (`render()`), and a view draws itself
/// when its crop or size changes. An idle guest costs nothing (testing:
/// ten windows took 16% CPU with a 120 Hz link each).
final class ZenCropView: NSView {
    private let renderer: ZenRenderer
    private weak var input: ZenInputSink?
    private var lastSerial: UInt64 = 0
    private var lastCrop = (u: 0.0, v: 0.0, width: 0.0, height: 0.0)
    private var tracking: NSTrackingArea?

    var textureRect = (u: 0.0, v: 0.0, width: 0.0, height: 0.0) {
        didSet { if textureRect != oldValue { render() } }
    }
    /// The guest window's size in Mac points. The crop is drawn at this size
    /// from the top-left, never stretched to the view: during a live resize
    /// the view leads and the guest catches up (the gap is background).
    var contentSize: CGSize = .zero {
        didSet { if contentSize != oldValue { lastSerial = 0; render() } }
    }
    /// Shown where the guest window has not caught up with a resize yet.
    private static let gapColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    /// True while macOS drags the window (started from the Windows title bar).
    private(set) var isDragging = false
    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            window?.invalidateShadow()  // the shadow follows the rounded shape
        }
    }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: ZenRenderer, input: ZenInputSink) {
        self.renderer = renderer
        self.input = input
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer.device
        l.pixelFormat = .bgra8Unorm
        l.isOpaque = false            // rounded corners show what is behind
        l.masksToBounds = true
        l.cornerCurve = .continuous
        l.cornerRadius = cornerRadius  // may be set before the layer exists
        l.displaySyncEnabled = true
        l.framebufferOnly = true
        return l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if tracking == nil {  // once: this runs again whenever the view changes window
            let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }
        window.acceptsMouseMovedEvents = true
        layer?.cornerRadius = cornerRadius
        window.invalidateShadow()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        lastSerial = 0  // redraw at the new size
        render()
    }

    /// Draws the latest frame if it, the crop or the size changed.
    func render() {
        guard let cb = renderer.queue.makeCommandBuffer() else { return }
        if encode(into: cb) { cb.commit() }
    }

    /// Encodes this window's draw into `cb` (the session batches every
    /// window of one frame into a single command buffer). False if nothing
    /// needed drawing.
    @discardableResult
    func encode(into cb: MTLCommandBuffer) -> Bool {
        guard let window, let (texture, serial) = renderer.currentTexture() else { return false }
        guard serial != lastSerial || textureRect != lastCrop, textureRect.width > 0, textureRect.height > 0 else { return false }
        let fit = ZenGeometry.fit(crop: textureRect, content: contentSize, view: bounds.size)
        guard fit.size.width > 0, fit.size.height > 0, let drawable = metalLayer.nextDrawable() else { return false }
        lastSerial = serial
        lastCrop = textureRect
        let crop = fit.crop
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = Self.gapColor
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return false }
        let scale = Double(window.backingScaleFactor)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                    width: min(Double(fit.size.width) * scale, Double(drawable.texture.width)),
                                    height: min(Double(fit.size.height) * scale, Double(drawable.texture.height)),
                                    znear: 0, zfar: 1))
        enc.setRenderPipelineState(renderer.pipeline)
        enc.setFragmentTexture(texture, index: 0)
        var c = SIMD4<Float>(Float(crop.u), Float(crop.v), Float(crop.width), Float(crop.height))
        enc.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        return true
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func macPoint(_ e: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: e.locationInWindow)
    }

    private var zenWindow: ZenWindow? { window as? ZenWindow }

    override func mouseMoved(with e: NSEvent) { if let w = zenWindow { input?.pointer(atMac: macPoint(e), in: w, hover: true) } }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func otherMouseDragged(with e: NSEvent) { drag(e) }
    private func drag(_ e: NSEvent) { if let w = zenWindow { input?.pointer(atMac: macPoint(e), in: w, hover: false) } }

    override func mouseDown(with e: NSEvent) {
        guard let w = zenWindow else { return }
        let p = macPoint(e)
        // A single click-and-drag on the Windows title bar moves the Mac
        // window natively (no lag, Mac snapping and tiling); the guest window
        // stays put. Double-clicks still go to Windows, which maximises or restores.
        if e.clickCount == 1, input?.hitArea(atMac: p, in: w) == .caption {
            isDragging = true
            w.performDrag(with: e)  // returns when the drag ends
            isDragging = false
            return
        }
        input?.button(0, down: true, atMac: p, in: w)
    }

    private func button(_ n: Int, _ down: Bool, _ e: NSEvent) {
        if let w = zenWindow { input?.button(n, down: down, atMac: macPoint(e), in: w) }
    }
    override func mouseUp(with e: NSEvent) { button(0, false, e) }
    override func rightMouseDown(with e: NSEvent) { button(1, true, e) }
    override func rightMouseUp(with e: NSEvent) { button(1, false, e) }
    override func otherMouseDown(with e: NSEvent) { button(e.buttonNumber, true, e) }
    override func otherMouseUp(with e: NSEvent) { button(e.buttonNumber, false, e) }
    override func scrollWheel(with e: NSEvent) {
        input?.scroll(deltaX: e.scrollingDeltaX, deltaY: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
                      newGesture: e.phase == .began || e.phase == .mayBegin)
    }
    override func keyDown(with e: NSEvent) { if !e.isARepeat { input?.key(code: e.keyCode, down: true) } }
    override func keyUp(with e: NSEvent) { input?.key(code: e.keyCode, down: false) }
    override func flagsChanged(with e: NSEvent) { input?.modifiers(code: e.keyCode, flags: e.modifierFlags) }
    override func resignFirstResponder() -> Bool { input?.lostFocus(); return true }
}
