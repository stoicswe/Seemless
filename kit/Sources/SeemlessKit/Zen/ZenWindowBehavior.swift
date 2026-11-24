import CoreGraphics
import Foundation

/// What a mouse-down on a guest window means for the host (docs/05 "The Zen
/// window": host-driven move and resize). Derived from the agent's
/// `HitTestResult`, which carries Windows' `WM_NCHITTEST` code.
public enum ZenHitArea: Sendable, Equatable {
    /// Title bar: the Mac moves the window natively, then tells the guest.
    case caption
    /// A resize border or corner: the Mac resizes natively, then tells the guest.
    case resize(ZenEdges)
    /// Client area, the min/max/close buttons, the system menu, scroll bars
    /// and anything unknown: the click goes to the guest as is.
    case passThrough

    /// Windows `HT*` codes (winuser.h).
    public enum Code {
        public static let client: Int32 = 1, caption: Int32 = 2, sysMenu: Int32 = 3
        public static let minButton: Int32 = 8, maxButton: Int32 = 9
        public static let left: Int32 = 10, right: Int32 = 11, top: Int32 = 12
        public static let topLeft: Int32 = 13, topRight: Int32 = 14, bottom: Int32 = 15
        public static let bottomLeft: Int32 = 16, bottomRight: Int32 = 17
        public static let close: Int32 = 20
    }

    public init(hitTestCode code: Int32) {
        switch code {
        case Code.caption: self = .caption
        case Code.left: self = .resize([.left])
        case Code.right: self = .resize([.right])
        case Code.top: self = .resize([.top])
        case Code.bottom: self = .resize([.bottom])
        case Code.topLeft: self = .resize([.top, .left])
        case Code.topRight: self = .resize([.top, .right])
        case Code.bottomLeft: self = .resize([.bottom, .left])
        case Code.bottomRight: self = .resize([.bottom, .right])
        default: self = .passThrough
        }
    }
}

extension ZenHitArea {
    /// A stand-in for the agent's `HitTest` when it cannot answer (no agent
    /// yet, or an agent without the request): the caption strip of a
    /// standard Windows 11 frame at the guest's DPI, minus its three buttons.
    /// Everything else, the buttons included, goes to the guest. Apps with
    /// custom title bars differ (Notepad's tabs sit in its caption), so the
    /// agent's answer always wins when there is one. Resize is not guessed:
    /// macOS's own edge resizing handles the borders.
    public static func standardFrame(at p: CGPoint, window r: GuestRect, dpiScale: Double = 1) -> ZenHitArea {
        let caption = Double(SimulatedWindowManager.captionHeight) * dpiScale
        let buttons = Double(3 * SimulatedWindowManager.buttonWidth) * dpiScale
        let x = p.x - Double(r.x), y = p.y - Double(r.y)
        guard x >= 0, y >= 0, x < Double(r.width), y < caption, x < Double(r.width) - buttons else { return .passThrough }
        return .caption
    }
}

public struct ZenEdges: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = ZenEdges(rawValue: 1), right = ZenEdges(rawValue: 2)
    public static let top = ZenEdges(rawValue: 4), bottom = ZenEdges(rawValue: 8)
}

extension GuestRect {
    /// The rectangle after dragging `edges` by (dx, dy) guest pixels, never
    /// smaller than `minSize` (the opposite edges stay put).
    public func resized(_ edges: ZenEdges, dx: Int, dy: Int, minWidth: Int = 160, minHeight: Int = 80) -> GuestRect {
        var r = self
        if edges.contains(.left) {
            let w = max(minWidth, width - dx)
            r.x = maxX - w; r.width = w
        }
        if edges.contains(.right) { r.width = max(minWidth, width + dx) }
        if edges.contains(.top) {
            let h = max(minHeight, height - dy)
            r.y = maxY - h; r.height = h
        }
        if edges.contains(.bottom) { r.height = max(minHeight, height + dy) }
        return r
    }

    public var protoRect: Seemless_V1_Rect {
        .with { $0.x = Int32(clamping: x); $0.y = Int32(clamping: y)
            $0.width = UInt32(clamping: max(0, width)); $0.height = UInt32(clamping: max(0, height)) }
    }
}

/// A tiny Windows window manager for the mock agent, so the Zen host can be
/// developed against realistic behaviour before the Windows agent exists:
/// it answers `HitTest` like `WM_NCHITTEST` on a Windows 11 frame, applies
/// `SetWindowRect` and `WindowCommand` (minimise, maximise, restore, close)
/// and reports the result as `WindowUpdated` / `WindowRemoved`, as the real
/// agent will. Pixels are not simulated.
public struct SimulatedWindowManager: Sendable {
    /// Windows 11 at 100%: 32 px caption, three 46 px buttons, 8 px resize band.
    public static let captionHeight = 32, buttonWidth = 46, resizeBand = 8

    public var workArea: GuestRect
    public private(set) var windows: [UInt64: Seemless_V1_Window] = [:]
    private var restoreRects: [UInt64: Seemless_V1_Rect] = [:]

    public init(workArea: GuestRect) { self.workArea = workArea }

    /// Learns the windows the script itself sends.
    public mutating func observe(_ body: Seemless_V1_Envelope.OneOf_Body) {
        switch body {
        case .windowSnapshot(let s):
            windows = [:]
            for w in s.windows { windows[w.id] = w }
        case .windowAdded(let a): windows[a.window.id] = a.window
        case .windowUpdated(let u):
            guard var w = windows[u.window.id] else { return }
            for f in u.changed {
                switch f {
                case .rect: w.rect = u.window.rect
                case .state: w.state = u.window.state
                case .title: w.title = u.window.title
                default: break
                }
            }
            windows[w.id] = w
        case .windowRemoved(let r): windows[r.id] = nil
        case .setHostInfo(let info) where info.hasWorkArea:
            let a = info.workArea
            workArea = GuestRect(x: Int(a.x), y: Int(a.y), width: Int(a.width), height: Int(a.height))
        default: break
        }
    }

    /// The reply and the window events for a host request it understands.
    public mutating func handle(_ body: Seemless_V1_Envelope.OneOf_Body)
        -> (reply: Seemless_V1_Envelope.OneOf_Body, events: [Seemless_V1_Envelope.OneOf_Body])? {
        switch body {
        case .hitTest(let h):
            guard let w = windows[h.id] else { return nil }
            return (.hitTestResult(.with { $0.code = Self.hitTest(w.rect, point: h.point, maximized: w.state == .maximized) }), [])
        case .setWindowRect(let s):
            guard var w = windows[s.id] else { return nil }
            w.rect = s.rect
            if w.state == .maximized { w.state = .normal }
            windows[w.id] = w
            return (.ack(.init()), [Self.updated(w, [.rect, .state])])
        case .windowCommand(let c):
            guard var w = windows[c.id] else { return nil }
            switch c.cmd {
            case .close:
                windows[w.id] = nil
                return (.ack(.init()), [.windowRemoved(.with { $0.id = w.id })])
            case .minimize:
                w.state = .minimized
            case .maximize:
                if w.state != .maximized { restoreRects[w.id] = w.rect }
                w.state = .maximized
                w.rect = workArea.protoRect
            case .restore:
                if w.state == .maximized, let r = restoreRects.removeValue(forKey: w.id) { w.rect = r }
                w.state = .normal
            default:
                return nil
            }
            windows[w.id] = w
            return (.ack(.init()), [Self.updated(w, [.rect, .state])])
        default:
            return nil
        }
    }

    private static func updated(_ w: Seemless_V1_Window, _ fields: [Seemless_V1_WindowField]) -> Seemless_V1_Envelope.OneOf_Body {
        .windowUpdated(.with { $0.window = w; $0.changed = fields })
    }

    /// `WM_NCHITTEST` for a Windows 11 frame; `point` is in guest screen pixels.
    public static func hitTest(_ r: Seemless_V1_Rect, point p: Seemless_V1_Point, maximized: Bool) -> Int32 {
        let x0 = Int(r.x), y0 = Int(r.y), x1 = x0 + Int(r.width), y1 = y0 + Int(r.height)
        let x = Int(p.x), y = Int(p.y)
        guard x >= x0, x < x1, y >= y0, y < y1 else { return 0 }  // HTNOWHERE
        typealias C = ZenHitArea.Code
        if !maximized {
            let b = resizeBand
            let l = x < x0 + b, rt = x >= x1 - b, t = y < y0 + b / 2, bm = y >= y1 - b
            switch (t, bm, l, rt) {
            case (true, _, true, _): return C.topLeft
            case (true, _, _, true): return C.topRight
            case (_, true, true, _): return C.bottomLeft
            case (_, true, _, true): return C.bottomRight
            case (true, _, _, _): return C.top
            case (_, true, _, _): return C.bottom
            case (_, _, true, _): return C.left
            case (_, _, _, true): return C.right
            default: break
            }
        }
        guard y < y0 + captionHeight else { return C.client }
        let fromRight = x1 - x
        if fromRight <= buttonWidth { return C.close }
        if fromRight <= 2 * buttonWidth { return C.maxButton }
        if fromRight <= 3 * buttonWidth { return C.minButton }
        return C.caption
    }
}

/// Paces the hover `HitTest` requests a Zen window sends while the pointer
/// moves over it (docs/05 "The Zen window", Moving).
///
/// Asking on every mouse-moved event sent ~25 requests a second (1,500 in a
/// minute of normal use). The answer only matters where a click lands, so:
/// nothing is asked when the cached answer was taken within `minDistance`,
/// at most one request is in flight, requests are at least `minInterval`
/// apart while the pointer moves, and when the pointer stops a trailing
/// request asks about the resting point, so a click there finds a fresh answer.
public struct HoverHitTestThrottle: Sendable {
    /// Seconds between requests while the pointer keeps moving (10 a second).
    public static let minInterval = 0.1
    /// Guest pixels the pointer must move from the cached answer before asking again.
    public static let minDistance = 3.0
    /// Seconds to wait before re-checking while a request is in flight.
    public static let retryDelay = 0.05
    /// Guest pixels from where it was taken that a cached answer is trusted for a click.
    public static let trustRadius = 6.0

    public enum Decision: Sendable, Equatable {
        /// Send a request for this point now (`requestSent` has been recorded).
        case sendNow
        /// Check again after this many seconds, with the pointer's position then.
        case retry(after: Double)
        /// The cached answer is good for this point.
        case skip
    }

    private var lastSentAt: Double?
    public private(set) var inFlight = false

    public init() {}

    /// The pointer is at guest point `p` at time `now` (seconds, any monotonic
    /// clock); `cachedAt` is where the cached answer was taken, if any.
    public mutating func pointerMoved(to p: CGPoint, now: Double, cachedAt: CGPoint?) -> Decision {
        if let c = cachedAt, abs(c.x - p.x) <= Self.minDistance, abs(c.y - p.y) <= Self.minDistance { return .skip }
        if inFlight { return .retry(after: Self.retryDelay) }
        if let last = lastSentAt, now - last < Self.minInterval {
            return .retry(after: Self.minInterval - (now - last))
        }
        lastSentAt = now
        inFlight = true
        return .sendNow
    }

    /// The request finished (answered, failed or timed out).
    public mutating func requestFinished() { inFlight = false }

    /// Whether a cached answer taken at `cachedAt` holds for a click at `p`.
    public static func trusts(_ cachedAt: CGPoint, for p: CGPoint) -> Bool {
        abs(cachedAt.x - p.x) <= trustRadius && abs(cachedAt.y - p.y) <= trustRadius
    }
}

/// Paces the size requests sent while a Zen window is being resized live, so
/// the guest app re-lays itself out as the edge moves (about 20 a second)
/// without a request per mouse event. The last size is always sent when the
/// resize ends.
public struct LiveResizePacer: Sendable {
    public static let minInterval = 0.05

    public enum Decision: Sendable, Equatable { case sendNow, sendAfter(Double), alreadyScheduled }

    private var lastSentAt: Double?
    private var scheduled = false

    public init() {}

    /// The size changed at `now` (seconds).
    public mutating func sizeChanged(now: Double) -> Decision {
        if scheduled { return .alreadyScheduled }
        if let last = lastSentAt, now - last < Self.minInterval {
            scheduled = true
            return .sendAfter(Self.minInterval - (now - last))
        }
        lastSentAt = now
        return .sendNow
    }

    /// A scheduled send ran at `now`.
    public mutating func scheduledSendRan(now: Double) {
        scheduled = false
        lastSentAt = now
    }
}
