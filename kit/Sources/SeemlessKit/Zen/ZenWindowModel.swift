import Foundation

/// A rectangle in guest pixels (scanout 0), origin top-left, as the agent
/// reports windows (`DWMWA_EXTENDED_FRAME_BOUNDS`).
public struct GuestRect: Sendable, Equatable, CustomStringConvertible {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func intersection(_ o: GuestRect) -> GuestRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return GuestRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public var description: String { "\(width)x\(height)+\(x)+\(y)" }
}

/// One guest window as the host keeps it: everything validated, because the
/// guest is untrusted (docs/06 "Host-side validation rules").
public struct ZenWindowInfo: Sendable, Equatable {
    public var id: UInt64
    public var ownerID: UInt64
    public var kind: Seemless_V1_WindowKind
    /// The part on the guest display: what the Zen window shows.
    public var rect: GuestRect
    /// As reported (sizes capped), possibly reaching off the display. Moves
    /// and resizes made on the Mac are applied to this rectangle, so a window
    /// that is partly off-screen keeps its real size in the guest.
    public var fullRect: GuestRect
    /// Plain text, control characters removed, at most `ZenWindowModel.maxTitleLength`.
    public var title: String
    public var appKey: String
    public var pid: UInt32
    public var state: Seemless_V1_WindowShowState
    public var resizable: Bool
    public var topmost: Bool
    public var hasAlpha: Bool
    public var iconID: UInt64

    /// Shown as its own Zen window in Z1: app windows and dialogs that are
    /// not minimised and have a visible area. Menus, tooltips and other
    /// transients become non-activating panels in Z5.
    public var isMirrored: Bool {
        guard !rect.isEmpty, state != .minimized else { return false }
        switch kind {
        case .normal, .dialog, .unspecified: return true
        default: return false
        }
    }
}

extension ZenWindowInfo {
    /// An app window that is open: mirrored now, or a minimised app window
    /// or dialog (still running, shown in the Dock).
    public var isOpenAppWindow: Bool {
        if isMirrored { return true }
        guard state == .minimized else { return false }
        switch kind {
        case .normal, .dialog, .unspecified: return true
        default: return false
        }
    }
}

/// Decides when Zen should hand over to the desktop window because the
/// guest closed its last app window (owner, 2026-11-24: "Closing all the
/// running programs that have windows in Zen mode should cause the VM to
/// show the full windows desktop view"). docs/05 "Mode transitions".
///
/// Fires only after open app windows went from some to none and stayed
/// none for `delay` (an app that swaps a splash screen for its main window
/// must not flip to the desktop and back). Starting with no windows never
/// fires. Agent loss, VM stop and Exit Zen end the session instead, so
/// they never reach here. Pure logic: the session feeds it and runs the timer.
public struct ZenLastWindowWatch: Sendable, Equatable {
    public static let defaultDelay = 0.3
    public let delay: Double
    /// Some app window has been open since the start (or the last reset).
    public private(set) var sawWindows = false
    /// When the set became empty, while a switch is pending.
    public private(set) var emptySince: Double?

    public init(delay: Double = Self.defaultDelay) { self.delay = delay }

    public enum Action: Sendable, Equatable {
        case none
        /// Check again (`shouldSwitch`) after this many seconds.
        case checkAfter(Double)
    }

    /// Call after every change to the window model.
    public mutating func update(hasOpenWindows: Bool, now: Double) -> Action {
        if hasOpenWindows {
            sawWindows = true
            emptySince = nil              // a new window cancels a pending switch
            return .none
        }
        guard sawWindows, emptySince == nil else { return .none }
        emptySince = now
        return .checkAfter(delay)
    }

    /// At the timer: true if the set is still empty and has been for `delay`.
    public func shouldSwitch(hasOpenWindows: Bool, now: Double) -> Bool {
        guard !hasOpenWindows, let since = emptySince else { return false }
        return now - since >= delay - 1e-9
    }

    /// Forget the history (a restarted agent: its snapshot is a fresh start).
    public mutating func reset() {
        sawWindows = false
        emptySince = nil
    }
}

/// The host's view of the guest's top-level windows, built from the agent's
/// `WindowSnapshot` / `WindowAdded` / `WindowUpdated` / `WindowRemoved`
/// messages (docs/05, docs/06). Pure logic; the Zen UI applies its changes.
public struct ZenWindowModel: Sendable {
    public static let maxWindows = 512
    public static let maxTitleLength = 256
    public static let maxAppKeyLength = 256

    public enum Change: Sendable, Equatable {
        case added(ZenWindowInfo)
        case updated(ZenWindowInfo)
        case removed(UInt64)
    }

    /// Guest display bounds; window rectangles are clamped to it.
    public var bounds: GuestRect
    public private(set) var windows: [UInt64: ZenWindowInfo] = [:]
    /// Back-to-front, as the snapshot gave it; new windows go on top.
    public private(set) var order: [UInt64] = []
    /// Messages ignored by validation (for diagnostics and tests).
    public private(set) var rejected = 0

    public init(bounds: GuestRect) { self.bounds = bounds }

    /// The guest display changed size: every window is clipped again.
    public mutating func setBounds(_ newBounds: GuestRect) -> [Change] {
        guard newBounds != bounds else { return [] }
        bounds = newBounds
        var changes: [Change] = []
        for id in order {
            guard var info = windows[id] else { continue }
            let visible = info.fullRect.intersection(bounds)
            guard visible != info.rect else { continue }
            info.rect = visible
            windows[id] = info
            changes.append(.updated(info))
        }
        return changes
    }

    public var mirrored: [ZenWindowInfo] { order.compactMap { windows[$0] }.filter(\.isMirrored) }

    /// True while some app window is open: mirrored, or minimised (the app
    /// still runs; it sits in the Dock). Drives `ZenLastWindowWatch`.
    public var hasOpenAppWindows: Bool { windows.values.contains { $0.isOpenAppWindow } }

    /// Applies one agent message. Bodies that are not about windows give no changes.
    public mutating func apply(_ body: Seemless_V1_Envelope.OneOf_Body) -> [Change] {
        switch body {
        case .windowSnapshot(let snap): return applySnapshot(snap.windows)
        case .windowAdded(let added): return upsert(added.window).map { [$0] } ?? []
        case .windowUpdated(let upd): return update(upd.window, changed: upd.changed).map { [$0] } ?? []
        case .windowRemoved(let rem):
            guard windows.removeValue(forKey: rem.id) != nil else { return [] }
            order.removeAll { $0 == rem.id }
            return [.removed(rem.id)]
        default: return []
        }
    }

    /// After a (re)connect the agent sends a full snapshot and the host
    /// discards what it had (docs/06).
    private mutating func applySnapshot(_ list: [Seemless_V1_Window]) -> [Change] {
        var next: [UInt64: ZenWindowInfo] = [:]
        var nextOrder: [UInt64] = []
        for w in list {
            guard nextOrder.count < Self.maxWindows else { rejected += 1; continue }
            guard let info = validated(w), next[info.id] == nil else { rejected += 1; continue }
            next[info.id] = info
            nextOrder.append(info.id)
        }
        var changes: [Change] = []
        for id in order where next[id] == nil { changes.append(.removed(id)) }
        for id in nextOrder {
            let info = next[id]!
            if let old = windows[id] {
                if old != info { changes.append(.updated(info)) }
            } else {
                changes.append(.added(info))
            }
        }
        windows = next
        order = nextOrder
        return changes
    }

    private mutating func upsert(_ w: Seemless_V1_Window) -> Change? {
        guard let info = validated(w) else { rejected += 1; return nil }
        if let old = windows[info.id] {
            windows[info.id] = info
            return old == info ? nil : .updated(info)
        }
        guard windows.count < Self.maxWindows else { rejected += 1; return nil }
        windows[info.id] = info
        order.append(info.id)
        return .added(info)
    }

    /// `WindowUpdated` is field-masked: only the fields in `changed` count.
    private mutating func update(_ w: Seemless_V1_Window, changed: [Seemless_V1_WindowField]) -> Change? {
        guard var info = windows[w.id] else { rejected += 1; return nil }
        let old = info
        for field in changed {
            switch field {
            case .ownerID: info.ownerID = w.ownerID
            case .kind: info.kind = w.kind
            case .rect:
                info.fullRect = Self.sanitized(w.rect)
                info.rect = info.fullRect.intersection(bounds)
            case .title: info.title = Self.plainText(w.title, max: Self.maxTitleLength)
            case .appKey: info.appKey = Self.plainText(w.appKey, max: Self.maxAppKeyLength)
            case .pid: info.pid = w.pid
            case .state: info.state = w.state
            case .flags:
                info.resizable = w.flags.resizable
                info.topmost = w.flags.topmost
                info.hasAlpha = w.flags.hasAlpha_p
            case .iconID: info.iconID = w.iconID
            default: break  // unknown fields from a newer agent are ignored
            }
        }
        guard info != old else { return nil }
        windows[w.id] = info
        return .updated(info)
    }

    private func validated(_ w: Seemless_V1_Window) -> ZenWindowInfo? {
        guard w.id != 0, w.id != w.ownerID else { return nil }
        let full = Self.sanitized(w.rect)
        return ZenWindowInfo(
            id: w.id, ownerID: w.ownerID, kind: w.kind, rect: full.intersection(bounds), fullRect: full,
            title: Self.plainText(w.title, max: Self.maxTitleLength),
            appKey: Self.plainText(w.appKey, max: Self.maxAppKeyLength),
            pid: w.pid, state: w.state, resizable: w.flags.resizable, topmost: w.flags.topmost,
            hasAlpha: w.flags.hasAlpha_p, iconID: w.iconID)
    }

    /// Largest coordinate or size accepted from the guest (Windows' own
    /// virtual-screen limit is far below this).
    public static let maxCoordinate = 1 << 20

    /// The reported rectangle with every value capped, so arithmetic on it
    /// can never overflow (the guest is untrusted).
    private static func sanitized(_ r: Seemless_V1_Rect) -> GuestRect {
        let m = maxCoordinate
        let w = Int(min(r.width, UInt32(m))), h = Int(min(r.height, UInt32(m)))
        return GuestRect(x: min(max(Int(r.x), -m), m), y: min(max(Int(r.y), -m), m), width: w, height: h)
    }

    /// Text shown in the Mac UI: no control characters, no rich text, capped.
    static func plainText(_ s: String, max: Int) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }))
        return String(cleaned.prefix(max))
    }
}
