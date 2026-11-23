import Foundation

/// Runs a short-lived tool (qemu-img, hdiutil) to completion.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String

        public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    public struct Failure: Error, CustomStringConvertible {
        public var command: String
        public var output: Output
        public var description: String {
            "\(command) exited \(output.status): \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// Runs `executable` with `arguments`; throws `Failure` on non-zero exit
    /// unless `check` is false. Output is read on background threads so a
    /// chatty tool cannot fill a pipe and deadlock.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String],
                           environment: [String: String]? = nil,
                           check: Bool = true) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently with the process, not after it exits:
        // a tool that writes more than the pipe buffer would otherwise block
        // forever and never terminate.
        let stdoutData = Drain(out.fileHandleForReading)
        let stderrData = Drain(err.fileHandleForReading)

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        let output = Output(
            status: status,
            stdout: stdoutData.wait(),
            stderr: String(decoding: stderrData.wait(), as: UTF8.self))
        if check && status != 0 {
            throw Failure(command: ([executable.lastPathComponent] + arguments).joined(separator: " "), output: output)
        }
        return output
    }
}

/// Reads a file handle to EOF on its own thread.
private final class Drain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }.start()
    }

    /// Blocks until EOF. Call only after the process has exited.
    func wait() -> Data {
        done.wait()
        return data
    }
}
