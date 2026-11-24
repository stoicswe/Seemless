import CoreGraphics
import Foundation

/// How guest pixels map to the Mac screen (WP3.5 HiDPI).
public enum DisplayScaling: String, Codable, Sendable, CaseIterable {
    /// One guest pixel per Mac point. Windows looks the size it would on a
    /// normal monitor; on a Retina screen each guest pixel is drawn 2×2.
    case standard
    /// One guest pixel per Mac screen pixel: sharp text, and Windows is told
    /// the real physical size so it can pick a high scale (set Settings ▸
    /// Display ▸ Scale to 200 % if it does not).
    case retina

    public var title: String {
        switch self {
        case .standard: "Standard (larger, softer)"
        case .retina: "Retina (sharp; use 200 % scale in Windows)"
        }
    }

    /// Guest pixels per Mac point on a screen with this backing scale.
    public func pixelsPerPoint(backingScale: CGFloat) -> CGFloat {
        switch self {
        case .standard: 1
        case .retina: max(1, backingScale)
        }
    }
}

/// Per-VM desktop window preferences (`vms/<name>/display.json`). Kept out
/// of `VMConfig`: they change nothing about the VM itself.
public struct DisplayPreferences: Codable, Sendable, Equatable {
    public var scaling: DisplayScaling
    public var keyboard: KeyboardStyle
    /// Resizing the window (or full screen) asks Windows for a matching
    /// resolution. Off: the window scales the guest screen, aspect kept.
    public var resizeGuest: Bool

    public init(scaling: DisplayScaling = .standard, keyboard: KeyboardStyle = .mac, resizeGuest: Bool = true) {
        self.scaling = scaling
        self.keyboard = keyboard
        self.resizeGuest = resizeGuest
    }

    private enum CodingKeys: String, CodingKey { case scaling, keyboard, resizeGuest }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scaling = (try? c.decodeIfPresent(DisplayScaling.self, forKey: .scaling)) ?? .standard
        keyboard = (try? c.decodeIfPresent(KeyboardStyle.self, forKey: .keyboard)) ?? .mac
        resizeGuest = (try? c.decodeIfPresent(Bool.self, forKey: .resizeGuest)) ?? true
    }

    public static func file(for files: VMFiles) -> URL { files.directory.appending(path: "display.json") }

    /// Defaults when the file is missing or unreadable.
    public static func load(_ files: VMFiles) -> DisplayPreferences {
        guard let data = try? Data(contentsOf: file(for: files)),
              let p = try? JSONDecoder().decode(DisplayPreferences.self, from: data) else { return DisplayPreferences() }
        return p
    }

    public func save(_ files: VMFiles) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.file(for: files), options: .atomic)
    }
}

/// Guest resolution requests for a resizable desktop window (WP3.2).
public enum DisplayResize {
    /// Smallest size asked of the guest (Windows' own minimum is 800×600).
    public static let minimum = (width: 800, height: 600)
    /// Largest: 8K, well inside the protocol's 16384 and the 8 GB host memory window.
    public static let maximum = (width: 7680, height: 4320)

    /// The guest size for a window content area of `content` points:
    /// `pixelsPerPoint` guest pixels per point, width a multiple of 8 and
    /// height even (scanout strides stay aligned), clamped to the limits.
    public static func guestSize(forContent content: CGSize, pixelsPerPoint: CGFloat) -> (width: Int, height: Int) {
        let ppp = max(pixelsPerPoint, 0.25)
        var w = Int((content.width * ppp).rounded(.down)) / 8 * 8
        var h = Int((content.height * ppp).rounded(.down)) / 2 * 2
        w = min(max(w, minimum.width), maximum.width)
        h = min(max(h, minimum.height), maximum.height)
        return (w, h)
    }

    /// Physical size in millimetres for a content area, from the screen it
    /// is on (points and millimetres of that screen), for the guest's EDID.
    /// Zero when the screen does not report a size.
    public static func physicalSize(forContent content: CGSize, screenPoints: CGSize,
                                    screenMillimetres: CGSize) -> (width: Int, height: Int) {
        guard screenPoints.width > 0, screenPoints.height > 0,
              screenMillimetres.width > 0, screenMillimetres.height > 0 else { return (0, 0) }
        let w = content.width / screenPoints.width * screenMillimetres.width
        let h = content.height / screenPoints.height * screenMillimetres.height
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    /// Whether a guest size change answers our last request (true) or was
    /// the guest's own choice (false: the window should follow the guest).
    /// A request the guest adjusted by a few pixels still counts as ours.
    public static func isAnswer(guestWidth: Int, guestHeight: Int, to request: (width: Int, height: Int)?) -> Bool {
        guard let request else { return false }
        return abs(guestWidth - request.width) <= 8 && abs(guestHeight - request.height) <= 8
    }
}
