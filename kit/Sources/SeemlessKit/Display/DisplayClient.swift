import CSeemlessDisplay
import CryptoKit
import Foundation
import IOSurface

/// Bootstrap name under which a VM's QEMU (`-display seemless`) checks in its
/// display port. Derived from the run directory so VMs under different
/// storage roots never collide; the CLI and the app compute the same name.
public enum DisplayExport {
    public static func serviceName(for run: RunPaths) -> String {
        let path = run.directory.standardizedFileURL.path(percentEncoded: false)
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "app.seemless.display.\(hex)"
    }
}

/// One scanout's current surface ring (protocol: patches/qemu/0001 header).
public struct DisplayScanout: @unchecked Sendable {
    public var head: UInt32
    public var generation: UInt32
    public var width: Int
    public var height: Int
    public var fourcc: UInt32
    public var surfaces: [IOSurfaceRef]
}

/// A finished frame: the pixels are in `surface` until QEMU reuses the slot
/// (at least two frames later, or never while we `acknowledge` it).
public struct DisplayFrame: @unchecked Sendable {
    public var head: UInt32
    public var generation: UInt32
    public var index: Int
    public var serial: UInt64
    /// 1 = CPU copy of a 2D surface (firmware, Basic Display), 2 = GPU blit of a Metal scanout.
    public var source: UInt32
    public var width: Int
    public var height: Int
    public var fourcc: UInt32
    public var surface: IOSurfaceRef
    /// `mach_absolute_time` stamps from QEMU and from our receive.
    public var tUpdate: UInt64, tReady: UInt64, tReceived: UInt64
}

/// Guest cursor image (32-bit 0xAARRGGBB per pixel, host order) and hotspot.
public struct DisplayCursor: Sendable, Equatable {
    public var head: UInt32
    public var serial: UInt32
    public var width: Int, height: Int
    public var hotX: Int, hotY: Int
    public var pixels: Data
}

public struct DisplayPointer: Sendable, Equatable {
    public var x: Int, y: Int
    public var visible: Bool
}

public enum DisplayError: Error, CustomStringConvertible, Equatable {
    case notExported(String)
    case connectFailed(Int32)
    case timeout(String)
    case closed

    public var description: String {
        switch self {
        case .notExported(let name):
            "no display export named \(name) (is the VM running with -display seemless?)"
        case .connectFailed(let kr): "connect to the display export failed (kern_return \(kr))"
        case .timeout(let what): "timed out waiting for \(what)"
        case .closed: "display client closed"
        }
    }
}

/// Client of QEMU's `ui/seemless` backend: receives the IOSurface rings,
/// frame, cursor and pointer events, and sends size requests. Thread-safe;
/// one receive thread per client.
public final class DisplayClient: @unchecked Sendable {
    public let service: String
    private let server: mach_port_t
    private let port: mach_port_t
    private let lock = NSLock()
    private var scanouts: [UInt32: DisplayScanout] = [:]
    private var frames: [UInt32: DisplayFrame] = [:]
    private var cursors: [UInt32: DisplayCursor] = [:]
    private var pointers: [UInt32: DisplayPointer] = [:]
    private var waiters: [(id: UUID, head: UInt32, after: UInt64, cont: CheckedContinuation<DisplayFrame, Error>)] = []
    private var closed = false
    /// Messages dropped by validation (for tests and diagnostics).
    public private(set) var rejectedMessages = 0

    /// Connects to the export of a running VM.
    public convenience init(run: RunPaths) throws {
        try self.init(service: DisplayExport.serviceName(for: run))
    }

    public init(service: String) throws {
        self.service = service
        var kr: kern_return_t = 0
        server = sld_lookup(service, &kr)
        guard server != 0 else { throw DisplayError.notExported(service) }
        port = sld_make_receive_port()
        kr = sld_connect(server, port)
        guard kr == KERN_SUCCESS else {
            sld_destroy_receive_port(port)
            mach_port_deallocate(mach_task_self_, server)
            throw DisplayError.connectFailed(kr)
        }
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "seemless.display.client"
        thread.start()
    }

    deinit { close() }

    /// Stops receiving and fails pending waits. QEMU drops us on its next send.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for w in pending { w.cont.resume(throwing: DisplayError.closed) }
    }

    private func receiveLoop() {
        while true {
            lock.lock(); let done = closed; lock.unlock()
            if done { break }
            var ev = sld_receive(port, 200)
            handle(&ev)
        }
        sld_destroy_receive_port(port)
        mach_port_deallocate(mach_task_self_, server)
    }

    private func handle(_ ev: inout SLDEvent) {
        var ready: [CheckedContinuation<DisplayFrame, Error>] = []
        var frame: DisplayFrame?
        lock.lock()
        switch ev.kind {
        case SLD_EV_SURFACES:
            // sld_receive hands over +1 references (IOSurfaceLookupFromMachPort).
            let surfaces = withUnsafeBytes(of: &ev.surfaces) {
                Array($0.bindMemory(to: Unmanaged<IOSurfaceRef>?.self))
            }.compactMap { $0?.takeRetainedValue() }
            scanouts[ev.head] = DisplayScanout(head: ev.head, generation: ev.generation, width: Int(ev.width),
                                               height: Int(ev.height), fourcc: ev.fourcc, surfaces: surfaces)
            frames[ev.head] = nil
        case SLD_EV_FRAME:
            if let s = scanouts[ev.head], s.generation == ev.generation, Int(ev.index) < s.surfaces.count {
                let f = DisplayFrame(head: ev.head, generation: ev.generation, index: Int(ev.index), serial: ev.serial,
                                     source: ev.source, width: s.width, height: s.height, fourcc: s.fourcc,
                                     surface: s.surfaces[Int(ev.index)], tUpdate: ev.t_update, tReady: ev.t_ready,
                                     tReceived: ev.t_received)
                frames[ev.head] = f
                frame = f
                waiters.removeAll { w in
                    if w.head == f.head && f.serial > w.after { ready.append(w.cont); return true }
                    return false
                }
            }
        case SLD_EV_DISABLE:
            frames[ev.head] = nil
        case SLD_EV_CURSOR:
            let n = Int(ev.width) * Int(ev.height) * 4
            let data = Data(bytes: ev.pixels, count: n)
            free(ev.pixels)
            cursors[ev.head] = DisplayCursor(head: ev.head, serial: ev.cursor_serial, width: Int(ev.width),
                                             height: Int(ev.height), hotX: Int(ev.hot_x), hotY: Int(ev.hot_y),
                                             pixels: data)
        case SLD_EV_MOUSE:
            pointers[ev.head] = DisplayPointer(x: Int(ev.mouse_x), y: Int(ev.mouse_y), visible: ev.visible)
        case SLD_EV_INVALID:
            rejectedMessages += 1
        case SLD_EV_ERROR:
            closed = true
        default:
            break
        }
        lock.unlock()
        if let frame { ready.forEach { $0.resume(returning: frame) } }
    }

    // MARK: - state

    public func scanout(head: UInt32 = 0) -> DisplayScanout? {
        lock.lock(); defer { lock.unlock() }
        return scanouts[head]
    }

    public func latestFrame(head: UInt32 = 0) -> DisplayFrame? {
        lock.lock(); defer { lock.unlock() }
        return frames[head]
    }

    public func cursor(head: UInt32 = 0) -> DisplayCursor? {
        lock.lock(); defer { lock.unlock() }
        return cursors[head]
    }

    public func pointer(head: UInt32 = 0) -> DisplayPointer? {
        lock.lock(); defer { lock.unlock() }
        return pointers[head]
    }

    /// The next frame on `head` with a serial greater than `after`.
    public func nextFrame(head: UInt32 = 0, after: UInt64 = 0, timeout: Duration = .seconds(5)) async throws -> DisplayFrame {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire(id, what: "a frame on scanout \(head)")
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: DisplayError.closed)
                return
            }
            if let f = frames[head], f.serial > after {
                lock.unlock()
                cont.resume(returning: f)
                return
            }
            waiters.append((id, head, after, cont))
            lock.unlock()
        }
    }

    private func expire(_ id: UUID, what: String) {
        lock.lock()
        let idx = waiters.firstIndex { $0.id == id }
        let w = idx.map { waiters.remove(at: $0) }
        lock.unlock()
        w?.cont.resume(throwing: DisplayError.timeout(what))
    }

    // MARK: - requests

    /// Tell QEMU which slot we are reading so it is not overwritten.
    public func acknowledge(_ frame: DisplayFrame) {
        _ = sld_ack(server, port, frame.head, frame.generation, UInt32(frame.index))
    }

    /// Ask for a scanout size (QEMU passes it to the guest as display info /
    /// EDID; the guest driver decides whether to switch).
    public func requestSize(head: UInt32 = 0, width: Int, height: Int, widthMM: Int = 0, heightMM: Int = 0) throws {
        let kr = sld_set_size(server, port, head, UInt32(width), UInt32(height), UInt32(widthMM), UInt32(heightMM))
        guard kr == KERN_SUCCESS else { throw DisplayError.connectFailed(kr) }
    }
}
