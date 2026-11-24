// S3Latency (spike, throwaway): end-to-end "key sent → pixels on glass" for
// one window, measured identically for -display cocoa and S3Viewer.
//
//   S3Latency --window <CGWindowID> --qmp <socket> [--n 40] [--keys x,backspace]
//
// Sends QMP key presses (alternating the given qcodes, so the guest screen
// toggles) and watches the window with ScreenCaptureKit. The latency of one
// sample is SCStreamFrameInfo.displayTime of the first captured frame whose
// pixels differ from the frame before the key, minus the mach time just
// before the QMP write. Both clocks are mach_absolute_time.
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

_ = NSApplication.shared  // ScreenCaptureKit needs a CoreGraphics session
var windowID: CGWindowID = 0
var qmpPath = ""
var samples = 40
var keys = ["x", "backspace"]
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--window": windowID = CGWindowID(it.next()!)!
        case "--qmp": qmpPath = it.next()!
        case "--n": samples = Int(it.next()!)!
        case "--keys": keys = it.next()!.split(separator: ",").map(String.init)
        default: fatalError("unknown argument \(a)")
        }
    }
}

var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func ms(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6 }

// --- QMP (blocking, one command at a time) ---
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    qmpPath.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
}
precondition(withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
} == 0, "QMP connect failed")
func qmpSend(_ s: String) { let d = s + "\n"; _ = d.withCString { write(fd, $0, strlen($0)) } }
func drain() { var b = [UInt8](repeating: 0, count: 65536); _ = read(fd, &b, b.count) }
drain()                                   // greeting
qmpSend(#"{"execute":"qmp_capabilities"}"#); drain()
Thread.detachNewThread { var b = [UInt8](repeating: 0, count: 65536); while read(fd, &b, b.count) > 0 {} }

func keyEvent(_ q: String, _ down: Bool) -> String {
    #"{"type":"key","data":{"down":\#(down),"key":{"type":"qcode","data":"\#(q)"}}}"#
}

// --- capture ---
final class Watcher: NSObject, SCStreamOutput {
    let lock = NSLock()
    var lastSum: UInt64 = 0
    var lastDisplayTime: UInt64 = 0
    var frames = 0
    var waitingSince: UInt64 = 0      // 0 = not armed
    var baseline: UInt64 = 0
    var hit: UInt64 = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let displayTime = (att[.displayTime] as? UInt64) ?? 0
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb) / 4
        var sum: UInt64 = 0
        // skip the title bar (top 15%): it does not change with guest content
        for y in Swift.stride(from: h * 15 / 100, to: h, by: 2) {
            let row = base + y * stride
            for x in Swift.stride(from: 0, to: w, by: 2) { sum = sum &* 31 &+ UInt64(row[x]) }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        lock.lock()
        frames += 1
        lastSum = sum
        lastDisplayTime = displayTime
        if waitingSince != 0, hit == 0, sum != baseline, displayTime > waitingSince {
            hit = displayTime
        }
        lock.unlock()
    }
}

let watcher = Watcher()
let sem = DispatchSemaphore(value: 0)
var stream: SCStream!
Task.detached {  // detached: top-level code is MainActor and blocks on sem below
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
        fatalError("window \(windowID) not on screen")
    }
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(win.frame.width * 2); cfg.height = Int(win.frame.height * 2)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    cfg.queueDepth = 8
    cfg.showsCursor = false
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
    try await stream.startCapture()
    sem.signal()
}
Thread.detachNewThread {
    sem.wait()
    Thread.sleep(forTimeInterval: 1.0)

    var results: [Double] = []
    var misses = 0
    for i in 0..<samples {
        let q = keys[i % keys.count]
        // settle: pixels unchanged for 250 ms (both displays redraw continuously)
        var quietSince = Date()
        var lastSum: UInt64 = 1
        while Date().timeIntervalSince(quietSince) < 0.25 {
            watcher.lock.lock(); let f = watcher.lastSum; watcher.lock.unlock()
            if f != lastSum { lastSum = f; quietSince = Date() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: Double.random(in: 0...0.05))   // decorrelate from vsync / refresh timers
        watcher.lock.lock()
        watcher.baseline = watcher.lastSum
        watcher.hit = 0
        let t0 = mach_absolute_time()
        watcher.waitingSince = t0
        watcher.lock.unlock()
        qmpSend(#"{"execute":"input-send-event","arguments":{"events":[\#(keyEvent(q, true))]}}"#)
        Thread.sleep(forTimeInterval: 0.03)
        qmpSend(#"{"execute":"input-send-event","arguments":{"events":[\#(keyEvent(q, false))]}}"#)
        let deadline = Date().addingTimeInterval(1.0)
        var hit: UInt64 = 0
        while Date() < deadline {
            watcher.lock.lock(); hit = watcher.hit; watcher.lock.unlock()
            if hit != 0 { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        watcher.lock.lock(); watcher.waitingSince = 0; watcher.lock.unlock()
        if hit == 0 { misses += 1; continue }
        results.append(ms(hit - t0))
    }
    stream.stopCapture { _ in }

    let s = results.sorted()
    func p(_ q: Double) -> Double { s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
    let mean = s.reduce(0, +) / Double(max(s.count, 1))
    print(String(format: "n=%d misses=%d  min %.1f  p50 %.1f  mean %.1f  p90 %.1f  max %.1f ms",
                 s.count, misses, s.first ?? .nan, p(0.5), mean, p(0.9), s.last ?? .nan))
    print("raw: " + results.map { String(format: "%.1f", $0) }.joined(separator: " "))
    exit(0)
}
RunLoop.main.run()
