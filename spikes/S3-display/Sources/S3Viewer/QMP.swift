import Foundation

/// Minimal QMP client for input injection. Writes are fire-and-forget on a
/// serial queue; a reader thread matches replies to measure round trips.
final class QMP {
    private let fd: Int32
    private let queue = DispatchQueue(label: "s3.qmp")
    private let lock = NSLock()
    private var sent: [UInt64] = []   // mach time of each command awaiting a reply
    private(set) var roundTripsMs: [Double] = []

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { throw NSError(domain: "qmp", code: Int(errno)) }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
        send(["execute": "qmp_capabilities"])
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0a) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if obj["return"] != nil || obj["error"] != nil {
                    if let e = obj["error"] { FileHandle.standardError.write("qmp error: \(e)\n".data(using: .utf8)!) }
                    let now = mach_absolute_time()
                    lock.lock()
                    if !sent.isEmpty {
                        let t = sent.removeFirst()
                        roundTripsMs.append(machMs(now - t))
                    }
                    lock.unlock()
                }
            }
        }
    }

    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        queue.async { [self] in
            lock.lock(); sent.append(mach_absolute_time()); lock.unlock()
            data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        }
    }

    func inputEvents(_ events: [[String: Any]]) {
        send(["execute": "input-send-event", "arguments": ["events": events]])
    }

    func key(_ qcode: String, down: Bool) {
        inputEvents([["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": qcode]]]])
    }

    /// x, y in 0...1 of the guest screen; QEMU's absolute axes run 0...32767.
    func moveAbs(_ x: Double, _ y: Double) {
        let cx = Int((min(max(x, 0), 1) * 32767).rounded())
        let cy = Int((min(max(y, 0), 1) * 32767).rounded())
        inputEvents([
            ["type": "abs", "data": ["axis": "x", "value": cx]],
            ["type": "abs", "data": ["axis": "y", "value": cy]],
        ])
    }

    func button(_ b: String, down: Bool) {
        inputEvents([["type": "btn", "data": ["down": down, "button": b]]])
    }
}

private var timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
}()

func machMs(_ t: UInt64) -> Double {
    Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func machToSeconds(_ t: UInt64) -> Double { machMs(t) / 1000 }
