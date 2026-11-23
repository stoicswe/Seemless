import Darwin
import Foundation

/// Reads newline-delimited text from a file descriptor on its own thread.
///
/// Used for sockets that stay open and mostly idle (QMP, the guest agent).
/// Blocking in `read(2)` on a dedicated thread keeps the Swift concurrency
/// pool free; the stream finishes on EOF or error. The caller owns `fd`.
enum LineReader {
    static func lines(fd: Int32, maxLineBytes: Int = 16 * 1024 * 1024) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                loop: while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<n])
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        var line = buffer[buffer.startIndex..<nl]
                        if line.last == 0x0D { line = line.dropLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...nl)
                    }
                    // A peer that never sends a newline must not grow memory forever.
                    if buffer.count > maxLineBytes { break loop }
                }
                continuation.finish()
            }
            thread.name = "seemless.LineReader.fd\(fd)"
            thread.start()
        }
    }
}
