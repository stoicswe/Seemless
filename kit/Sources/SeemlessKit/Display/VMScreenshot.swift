import CoreGraphics
import Foundation
import ImageIO

/// A PNG of a running VM's screen, and where it came from.
public struct VMScreenshot: Sendable {
    public enum Source: String, Sendable {
        /// Exported IOSurface, 2D surface (firmware, Basic Display).
        case exported2D = "exported (2d)"
        /// Exported IOSurface, GPU copy of the 3D driver's scanout.
        case exportedMetal = "exported (metal)"
        /// QMP `screendump`: the VM runs in QEMU's own window. Black once the
        /// 3D driver owns the display.
        case qmpScreendump = "QMP screendump"
    }

    public var png: Data
    public var width: Int
    public var height: Int
    public var source: Source
    /// Fraction of sampled pixels that are not (near) black.
    public var nonBlackFraction: Double

    /// A screendump that came back black: almost certainly the 3D driver's
    /// scanout, which only the exported display can see.
    public var isLikelyBlankScreendump: Bool { source == .qmpScreendump && nonBlackFraction < 0.001 }

    /// "Seemless <vm> 2026-11-24 at 09.46.12.png", like macOS screenshots.
    public static func fileName(vm: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safe = vm.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "Seemless \(safe) \(f.string(from: date)).png"
    }

    /// Where macOS saves screenshots (`defaults read com.apple.screencapture
    /// location`), else the Desktop.
    public static func defaultDirectory(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture"),
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = defaults?.string(forKey: "location"), !path.isEmpty {
            let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return home.appending(path: "Desktop", directoryHint: .isDirectory)
    }
}

extension VMManager {
    /// Screenshot of a running VM's scanout: from the exported IOSurface when
    /// QEMU runs with `-display seemless` (works with the 3D driver), else
    /// QMP `screendump` (scanout 0 only).
    public func screenshot(_ name: String, scanout: UInt32 = 0, timeout: Duration = .seconds(10)) async throws -> VMScreenshot {
        guard let record = RunningVM.read(store.files(for: name)), record.isAlive else {
            throw ManagerError.notRunning(name)
        }
        do {
            let client = try DisplayClient(run: record.run)
            defer { client.close() }
            let frame = try await client.nextFrame(head: scanout, timeout: timeout)
            client.acknowledge(frame)  // keep QEMU off this slot while we read it
            return VMScreenshot(png: try DisplayImage.png(frame.surface), width: frame.width, height: frame.height,
                                source: frame.source == 2 ? .exportedMetal : .exported2D,
                                nonBlackFraction: DisplayImage.nonBlackFraction(frame.surface))
        } catch DisplayError.notExported {
            // QEMU's own window (cocoa) or headless: fall back to QMP.
        }
        guard scanout == 0 else { throw DisplayError.notExported(DisplayExport.serviceName(for: record.run)) }
        let file = FileManager.default.temporaryDirectory.appending(path: "seemless-screendump-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await withQMP(name) { qmp in
            _ = try await qmp.execute("screendump", arguments: ["filename": .string(file.path(percentEncoded: false)),
                                                               "format": "png"])
        }
        let png = try Data(contentsOf: file)
        guard let image = CGImageSourceCreateWithData(png as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
        else { throw DisplayImage.ImageError.encodeFailed }
        return VMScreenshot(png: png, width: image.width, height: image.height, source: .qmpScreendump,
                            nonBlackFraction: DisplayImage.nonBlackFraction(image))
    }
}
