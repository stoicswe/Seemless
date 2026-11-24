import Foundation

/// Agent channel framing (docs/06 "Transport and framing"); the same rules
/// as `guest/agent/crates/proto/src/frame.rs`.
///
/// A frame is `u32 length (LE) | u8 kind | payload`; `length` is the payload
/// length. Kind 0 is an `Envelope`, kind 1 a raw bulk chunk (bulk port only).
/// After any framing error the channel must be reset: `Decoder` refuses
/// further input.
public enum AgentFrame {
    public static let headerLength = 5
    public static let maxControlPayload = 1 << 20
    public static let maxBulkPayload = 4 << 20

    public enum Kind: UInt8, Sendable {
        case envelope = 0
        case bulk = 1
    }

    public enum Channel: Sendable {
        case control, bulk

        public var maxPayload: Int { self == .control ? AgentFrame.maxControlPayload : AgentFrame.maxBulkPayload }

        func allows(_ kind: Kind) -> Bool { kind == .envelope || self == .bulk }
    }

    public struct Frame: Sendable, Equatable {
        public var kind: Kind
        public var payload: Data
    }

    public enum FrameError: Error, Equatable, CustomStringConvertible {
        case oversized(length: Int, max: Int)
        case unknownKind(UInt8)
        case kindNotAllowed(Kind, Channel)
        case reset

        public var description: String {
            switch self {
            case .oversized(let l, let m): return "frame of \(l) bytes exceeds \(m)"
            case .unknownKind(let k): return "unknown frame kind \(k)"
            case .kindNotAllowed(let k, let c): return "\(k) frame not allowed on the \(c) channel"
            case .reset: return "channel must be reset after a framing error"
            }
        }
    }

    public static func encode(_ kind: Kind = .envelope, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        var out = Data(capacity: headerLength + payload.count)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    public static func encode(_ envelope: Seemless_V1_Envelope) throws -> Data {
        encode(.envelope, payload: try envelope.serializedData())
    }

    /// Incremental decoder. The header is checked as soon as it arrives, so
    /// an oversized length fails before its payload is buffered.
    public struct Decoder: Sendable {
        public let channel: Channel
        private var buffer = Data()
        private var failed = false

        public init(channel: Channel) { self.channel = channel }

        public var buffered: Int { buffer.count }

        /// Frames completed by `bytes`, plus the error that ended decoding,
        /// if any. Frames before a bad one are still valid and are returned;
        /// after an error every later push reports `.reset`.
        public struct Output: Sendable, Equatable {
            public var frames: [Frame]
            public var error: FrameError?
        }

        public mutating func decode(_ bytes: Data) -> Output {
            guard !failed else { return Output(frames: [], error: .reset) }
            buffer.append(bytes)
            var frames: [Frame] = []
            do {
                while let frame = try next() { frames.append(frame) }
            } catch {
                failed = true
                buffer = Data()
                return Output(frames: frames, error: error)
            }
            return Output(frames: frames, error: nil)
        }

        /// `decode`, throwing on error (frames before the error are dropped).
        public mutating func push(_ bytes: Data) throws(FrameError) -> [Frame] {
            let out = decode(bytes)
            if let error = out.error { throw error }
            return out.frames
        }

        private mutating func next() throws(FrameError) -> Frame? {
            guard buffer.count >= AgentFrame.headerLength else { return nil }
            let base = buffer.startIndex
            var length = 0
            for i in 0..<4 { length |= Int(buffer[base + i]) << (8 * i) }
            guard length <= channel.maxPayload else { throw .oversized(length: length, max: channel.maxPayload) }
            guard let kind = Kind(rawValue: buffer[base + 4]) else { throw .unknownKind(buffer[base + 4]) }
            guard channel.allows(kind) else { throw .kindNotAllowed(kind, channel) }
            guard buffer.count >= AgentFrame.headerLength + length else { return nil }
            let start = base + AgentFrame.headerLength
            let payload = Data(buffer[start..<start + length])
            buffer = Data(buffer[(start + length)...])
            return Frame(kind: kind, payload: payload)
        }
    }
}

/// Reads raw bytes from a file descriptor on its own thread (like
/// `LineReader`): idle agent sockets must not hold Swift concurrency threads.
/// The stream finishes on EOF or error; the caller owns `fd`.
enum ByteReader {
    static func chunks(fd: Int32) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    continuation.yield(Data(chunk[0..<n]))
                }
                continuation.finish()
            }
            thread.name = "seemless.ByteReader.fd\(fd)"
            thread.start()
        }
    }
}
