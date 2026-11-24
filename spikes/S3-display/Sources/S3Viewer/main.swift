// S3Viewer (spike, throwaway): shows scanout 0 exported by QEMU's patched
// `-display seemless,service=NAME` in a CAMetalLayer at display refresh and
// sends keyboard/mouse back over QMP.
//
//   S3Viewer --service NAME --qmp /path/qmp.sock [--csv out.csv]
//
// stdin commands (for scripted checks, since nobody can click for us):
//   move X Y | click X Y | rclick X Y   (X, Y = 0...1 of the guest screen)
//   key QCODE [QCODE...]                (pressed together, released in reverse)
//   shot PATH.png | stats | winid | quit
import AppKit
import CMach
import IOSurface
import Metal
import QuartzCore

struct Options {
    var service = ""
    var qmp = ""
    var csv: String?
    var arrival = false       // draw when a frame arrives instead of on the display link
    var drawables = 3
    var pointsPerPixel = 0.0  // 0 = 1 device pixel per guest pixel (like -display cocoa)
    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--service": service = it.next() ?? ""
            case "--qmp": qmp = it.next() ?? ""
            case "--csv": csv = it.next()
            case "--arrival": arrival = true
            case "--drawables": drawables = Int(it.next()!)!
            case "--points-per-pixel": pointsPerPixel = Double(it.next()!)!
            default: fatalError("unknown argument \(a)")
            }
        }
        precondition(!service.isEmpty && !qmp.isEmpty, "need --service and --qmp")
    }
}

func log(_ s: String) { FileHandle.standardError.write("[S3Viewer] \(s)\n".data(using: .utf8)!) }

struct FrameRecord {
    var serial: UInt64, source: UInt32
    var tUpdate: UInt64, tReady: UInt64, tRecv: UInt64
    var tTick: Double = 0, tPresented: Double = 0
}

/// Shared state between the Mach receiver thread and the main thread.
final class Scanout {
    let lock = NSLock()
    var generation: UInt32 = 0
    var width = 0, height = 0, fourcc: UInt32 = 0
    var surfaces: [IOSurfaceRef] = []
    var textures: [MTLTexture] = []
    var latest: FrameRecord?
    var latestIndex = 0
    var frames: [FrameRecord] = []   // presented frames
    var received = 0, dropped = 0
}

final class Receiver {
    let port: mach_port_t
    let scanout: Scanout
    let device: MTLDevice
    var onSurfaces: ((Int, Int) -> Void)?

    init(service: String, scanout: Scanout, device: MTLDevice) {
        var kr: kern_return_t = 0
        port = sl_checkin(service, &kr)
        guard port != 0 else { fatalError("bootstrap_check_in(\(service)) failed: \(kr)") }
        log("checked in \(service)")
        self.scanout = scanout
        self.device = device
        Thread.detachNewThread { [self] in loop() }
    }

    private func loop() {
        while true {
            var ev = sl_receive(port, 0)
            switch ev.kind {
            case 1: adopt(&ev)
            case 2:
                scanout.lock.lock()
                if ev.generation == scanout.generation, Int(ev.index) < scanout.textures.count {
                    if scanout.latest != nil { scanout.dropped += 1 }  // replaced before display
                    scanout.latest = FrameRecord(serial: ev.serial, source: ev.source,
                                                 tUpdate: ev.t_update, tReady: ev.t_ready, tRecv: ev.t_recv)
                    scanout.latestIndex = Int(ev.index)
                    scanout.received += 1
                }
                scanout.lock.unlock()
                if opts.arrival { DispatchQueue.main.async { view.drawLatest() } }
            case -1: log("bad message ignored")
            default: break
            }
        }
    }

    private func adopt(_ ev: inout SLEvent) {
        let ports = withUnsafeBytes(of: &ev.ports) { Array($0.bindMemory(to: mach_port_t.self)) }
        var surfaces: [IOSurfaceRef] = []
        var textures: [MTLTexture] = []
        let w = Int(ev.width), h = Int(ev.height)
        let valid = w > 0 && h > 0 && w <= 16384 && h <= 16384
            && (ev.fourcc == 0x4247_5241 /* BGRA */ || ev.fourcc == 0x5247_4241 /* RGBA */)
        for p in ports {
            defer { mach_port_deallocate(mach_task_self_, p) }
            guard valid, let s = IOSurfaceLookupFromMachPort(p) else { continue }
            // Do not trust the header: the surface itself must match.
            guard IOSurfaceGetWidth(s) == w, IOSurfaceGetHeight(s) == h,
                  IOSurfaceGetPixelFormat(s) == ev.fourcc else { continue }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: ev.fourcc == 0x5247_4241 ? .rgba8Unorm : .bgra8Unorm,
                width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d, iosurface: s, plane: 0) else { continue }
            surfaces.append(s); textures.append(t)
        }
        guard surfaces.count == Int(SL_RING) else { log("surface set rejected"); return }
        scanout.lock.lock()
        scanout.generation = ev.generation
        scanout.width = w; scanout.height = h; scanout.fourcc = ev.fourcc
        scanout.surfaces = surfaces; scanout.textures = textures
        scanout.latest = nil
        scanout.lock.unlock()
        log("surfaces gen \(ev.generation): \(w)x\(h)")
        DispatchQueue.main.async { self.onSurfaces?(w, h) }
    }
}

final class ScanoutView: NSView {
    let scanout: Scanout
    let qmp: QMP
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var lastSerial: UInt64 = 0
    var link: CADisplayLink?

    init(scanout: Scanout, qmp: QMP, device: MTLDevice) {
        self.scanout = scanout; self.qmp = qmp; self.device = device
        queue = device.makeCommandQueue()!
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V vmain(uint i [[vertex_id]]) {
            float2 uv = float2((i << 1) & 2, i & 2);
            V v; v.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); v.uv = uv; return v;
        }
        fragment float4 fmain(V v [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            return float4(t.sample(s, v.uv).rgb, 1);
        }
        """
        let lib = try! device.makeLibrary(source: src, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.isOpaque = true
        l.displaySyncEnabled = true
        l.maximumDrawableCount = opts.drawables
        return l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        if !opts.arrival {
            link = displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        window?.acceptsMouseMovedEvents = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    @objc func tick(_ l: CADisplayLink) { drawLatest() }

    func drawLatest() {
        scanout.lock.lock()
        guard var rec = scanout.latest, rec.serial != lastSerial,
              scanout.latestIndex < scanout.textures.count else { scanout.lock.unlock(); return }
        let tex = scanout.textures[scanout.latestIndex]
        scanout.latest = nil
        scanout.lock.unlock()
        lastSerial = rec.serial
        rec.tTick = CACurrentMediaTime()

        guard let drawable = metalLayer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let sc = scanout
        drawable.addPresentedHandler { d in
            guard d.presentedTime > 0 else { return }
            var r = rec; r.tPresented = d.presentedTime
            sc.lock.lock(); sc.frames.append(r); sc.lock.unlock()
        }
        cb.present(drawable)
        cb.commit()
    }

    // MARK: input → QMP

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func guestPoint(_ e: NSEvent) -> (Double, Double) {
        let p = convert(e.locationInWindow, from: nil)
        return (Double(p.x / bounds.width), Double(1 - p.y / bounds.height))
    }
    override func mouseMoved(with e: NSEvent) { let (x, y) = guestPoint(e); qmp.moveAbs(x, y) }
    override func mouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseDown(with e: NSEvent) { mouseMoved(with: e); qmp.button("left", down: true) }
    override func mouseUp(with e: NSEvent) { mouseMoved(with: e); qmp.button("left", down: false) }
    override func rightMouseDown(with e: NSEvent) { mouseMoved(with: e); qmp.button("right", down: true) }
    override func rightMouseUp(with e: NSEvent) { mouseMoved(with: e); qmp.button("right", down: false) }
    override func scrollWheel(with e: NSEvent) {
        guard e.scrollingDeltaY != 0 else { return }
        let b = e.scrollingDeltaY > 0 ? "wheel-up" : "wheel-down"
        qmp.button(b, down: true); qmp.button(b, down: false)
    }
    override func keyDown(with e: NSEvent) {
        if e.isARepeat { return }
        if let q = qcodeForKeyCode[Int(e.keyCode)] { qmp.key(q, down: true) }
    }
    override func keyUp(with e: NSEvent) {
        if let q = qcodeForKeyCode[Int(e.keyCode)] { qmp.key(q, down: false) }
    }
    override func flagsChanged(with e: NSEvent) {
        guard let q = qcodeForKeyCode[Int(e.keyCode)] else { return }
        let mask: NSEvent.ModifierFlags = switch q {
        case "shift", "shift_r": .shift
        case "ctrl", "ctrl_r": .control
        case "alt", "alt_r": .option
        default: .command
        }
        qmp.key(q, down: e.modifierFlags.contains(mask))
    }
}

// MARK: - stats and commands

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func summary(_ sc: Scanout, qmp: QMP) -> String {
    sc.lock.lock(); let f = sc.frames; let rx = sc.received; let dr = sc.dropped; sc.lock.unlock()
    func row(_ name: String, _ v: [Double]) -> String {
        String(format: "%-28@ n=%4d  p50 %6.2f  p90 %6.2f  p99 %6.2f ms", name as NSString, v.count,
               percentile(v, 0.5), percentile(v, 0.9), percentile(v, 0.99))
    }
    let copy = f.map { machMs($0.tReady - $0.tUpdate) }
    let ipc = f.map { machMs($0.tRecv - $0.tReady) }
    let wait = f.map { $0.tTick - machToSeconds($0.tRecv) }.map { $0 * 1000 }
    let present = f.map { ($0.tPresented - $0.tTick) * 1000 }
    let total = f.map { ($0.tPresented - machToSeconds($0.tUpdate)) * 1000 }
    let rtt = qmp.roundTripsMs
    return [
        "frames received \(rx), presented \(f.count), replaced before display \(dr)",
        row("QEMU copy into IOSurface", copy),
        row("Mach message", ipc),
        row("wait for display link", wait),
        row("draw + present", present),
        row("total update→on glass", total),
        row("QMP input round trip", rtt),
    ].joined(separator: "\n")
}

func writePNG(_ sc: Scanout, path: String) -> Bool {
    sc.lock.lock()
    let s = sc.surfaces.isEmpty ? nil : sc.surfaces[sc.latestIndex]
    sc.lock.unlock()
    guard let s else { return false }
    let ci = CIImage(ioSurface: s)
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return false }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}

let opts = Options()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let device = MTLCreateSystemDefaultDevice()!
let scanout = Scanout()
let qmp: QMP = {
    for _ in 0..<100 {
        if let q = try? QMP(path: opts.qmp) { return q }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fatalError("cannot connect to QMP at \(opts.qmp)")
}()
let receiver = Receiver(service: opts.service, scanout: scanout, device: device)
let view = ScanoutView(scanout: scanout, qmp: qmp, device: device)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "S3Viewer — \(opts.service)"
window.contentView = view
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate()

receiver.onSurfaces = { w, h in
    let ppp = opts.pointsPerPixel > 0 ? opts.pointsPerPixel : 1 / window.backingScaleFactor
    window.setContentSize(NSSize(width: Double(w) * ppp, height: Double(h) * ppp))
    window.contentAspectRatio = NSSize(width: w, height: h)
}

func synthesize(_ cmd: String, _ p: [String], _ x: Double, _ y: Double) {
    let b = view.bounds
    let loc = view.convert(NSPoint(x: b.width * x, y: b.height * (1 - y)), to: nil)
    let wn = window.windowNumber
    if cmd == "nsclick" {
        for t: NSEvent.EventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: wn, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if t == .mouseMoved { view.mouseMoved(with: e) } else { window.sendEvent(e) }
        }
    } else {
        // nskey <keyCode> [<keyCode>...] (macOS virtual key codes)
        for code in p.dropFirst().compactMap({ UInt16($0) }) {
            for t: NSEvent.EventType in [.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: wn, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code)!
                window.sendEvent(e)
            }
        }
    }
}

Thread.detachNewThread {
    while let line = readLine() {
        let p = line.split(separator: " ").map(String.init)
        guard let cmd = p.first else { continue }
        let x = p.count > 2 ? Double(p[1]) ?? 0 : 0, y = p.count > 2 ? Double(p[2]) ?? 0 : 0
        switch cmd {
        case "move": qmp.moveAbs(x, y)
        case "click", "rclick":
            let b = cmd == "click" ? "left" : "right"
            qmp.moveAbs(x, y); Thread.sleep(forTimeInterval: 0.05)
            qmp.button(b, down: true); Thread.sleep(forTimeInterval: 0.05); qmp.button(b, down: false)
        case "key":
            let keys = Array(p.dropFirst())
            for k in keys { qmp.key(k, down: true); Thread.sleep(forTimeInterval: 0.03) }
            for k in keys.reversed() { qmp.key(k, down: false); Thread.sleep(forTimeInterval: 0.03) }
        case "nsclick", "nskey":
            // Synthetic NSEvents through NSWindow.sendEvent: exercises the
            // view's AppKit handlers and coordinate mapping (not HID delivery).
            DispatchQueue.main.sync { synthesize(cmd, p, x, y) }
        case "shot": print(writePNG(scanout, path: p.count > 1 ? p[1] : "shot.png") ? "ok" : "no surface")
        case "stats": print(summary(scanout, qmp: qmp))
        case "winid": DispatchQueue.main.sync { print(window.windowNumber) }
        case "quit": DispatchQueue.main.async { app.terminate(nil) }
        default: print("unknown command")
        }
        fflush(stdout)
    }
}

atexit {
    print(summary(scanout, qmp: qmp))
    if let csv = opts.csv {
        scanout.lock.lock(); let f = scanout.frames; scanout.lock.unlock()
        var out = "serial,source,update_to_ready_ms,ready_to_recv_ms,recv_to_tick_ms,tick_to_present_ms,total_ms\n"
        for r in f {
            out += String(format: "%llu,%u,%.3f,%.3f,%.3f,%.3f,%.3f\n", r.serial, r.source,
                          machMs(r.tReady - r.tUpdate), machMs(r.tRecv - r.tReady),
                          (r.tTick - machToSeconds(r.tRecv)) * 1000, (r.tPresented - r.tTick) * 1000,
                          (r.tPresented - machToSeconds(r.tUpdate)) * 1000)
        }
        try? out.write(toFile: csv, atomically: true, encoding: .utf8)
    }
}
app.run()
