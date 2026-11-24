import CoreGraphics
import Foundation

/// Maps between guest pixels (scanout 0, origin top-left) and the Mac's
/// global screen space (Cocoa points, origin bottom-left of the main display).
///
/// docs/05 "Geometry model": the guest display sits on a region of the Mac
/// desktop, so a window at guest pixel (x, y) is shown at the matching Mac
/// point, and menus or dialogs that apps place relative to their windows
/// land in the right place.
public struct ZenGeometry: Sendable, Equatable {
    /// Guest display size in pixels.
    public var guestWidth: Int
    public var guestHeight: Int
    /// The Mac point (global, Cocoa coordinates) that guest pixel (0, 0)
    /// (top-left) maps to.
    public var topLeft: CGPoint
    /// Mac points per guest pixel. `1 / backingScale` when the guest runs at
    /// the Mac's DPI (the goal, docs/05 "DPI"). 1 is a stand-in while the
    /// guest still runs at 100%: windows have the right size but are
    /// upscaled.
    public var pointsPerPixel: CGFloat

    public init(guestWidth: Int, guestHeight: Int, topLeft: CGPoint, pointsPerPixel: CGFloat) {
        self.guestWidth = guestWidth
        self.guestHeight = guestHeight
        self.topLeft = topLeft
        self.pointsPerPixel = pointsPerPixel
    }

    /// The Cocoa frame (global points) for a guest window rectangle.
    public func macFrame(for r: GuestRect) -> CGRect {
        let s = pointsPerPixel
        let x = topLeft.x + CGFloat(r.x) * s
        let top = topLeft.y - CGFloat(r.y) * s
        let h = CGFloat(r.height) * s
        return CGRect(x: x, y: top - h, width: CGFloat(r.width) * s, height: h)
    }

    /// The guest pixel under a Mac global point (may lie outside the display).
    public func guestPoint(fromMac p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - topLeft.x) / pointsPerPixel, y: (topLeft.y - p.y) / pointsPerPixel)
    }

    // MARK: Mac-only placement (owner, 2026-11-24)
    //
    // Moving a Zen window moves only the Mac window: "feel like a native Mac
    // app, but be the native app in the Windows VM". The guest window stays
    // where Windows has it; each Zen window keeps an offset (Mac points)
    // between where the plain mapping would put it and where it is. Input
    // goes through the same offset, so it still lands on the right pixel.

    /// The Cocoa frame for a guest rectangle shown with `offset`.
    public func macFrame(for r: GuestRect, offset: CGVector) -> CGRect {
        macFrame(for: r).offsetBy(dx: offset.dx, dy: offset.dy)
    }

    /// The offset that puts guest rectangle `r` at Mac frame `f` (top-left aligned).
    public func offset(placing r: GuestRect, at f: CGRect) -> CGVector {
        let plain = macFrame(for: r)
        return CGVector(dx: f.minX - plain.minX, dy: f.maxY - plain.maxY)
    }

    /// The guest pixel under a Mac point inside a window shown with `offset`.
    public func guestPoint(fromMac p: CGPoint, offset: CGVector) -> CGPoint {
        guestPoint(fromMac: CGPoint(x: p.x - offset.dx, y: p.y - offset.dy))
    }

    /// How a window's crop is drawn into its Zen view: 1:1 from the top-left,
    /// never stretched (owner, 2026-11-24: during a live resize the window
    /// must re-lay itself out, not stretch).
    ///
    /// `crop` is the window's part of the scanout (normalised, as
    /// `textureRect`), `content` its size in Mac points (guest size ×
    /// `pointsPerPixel`) and `view` the view's size. Where the view is larger
    /// than the content (the guest has not caught up with a resize yet) the
    /// rest is background; where it is smaller, the crop is cut to fit.
    /// Returns the crop to sample and the drawn size in points, from the top-left.
    public static func fit(crop: (u: Double, v: Double, width: Double, height: Double), content: CGSize, view: CGSize)
        -> (crop: (u: Double, v: Double, width: Double, height: Double), size: CGSize) {
        guard content.width > 0, content.height > 0 else { return (crop, .zero) }
        let w = min(content.width, view.width), h = min(content.height, view.height)
        let c = (u: crop.u, v: crop.v, width: crop.width * Double(w / content.width), height: crop.height * Double(h / content.height))
        return (c, CGSize(width: w, height: h))
    }

    /// Height of the Windows 11 taskbar at 100%, assumed until the agent
    /// reports the real work area.
    public static let assumedTaskbarHeight = 48

    /// The guest's usable area: the display minus the taskbar at the bottom
    /// (the agent will report the real one; docs/06 `SetHostInfo.work_area`).
    public var assumedWorkArea: GuestRect {
        GuestRect(x: 0, y: 0, width: guestWidth, height: max(1, guestHeight - Self.assumedTaskbarHeight))
    }

    /// Where a guest window of the wanted size should go so it lies wholly in
    /// the work area. Windows draws the taskbar and other windows on top, so
    /// any part outside would show them in the crop (testing, 2026-11-24).
    /// The Mac position is independent of the guest's (Mac-only moves), so
    /// the guest window can be moved freely to fit: it is shrunk to the work
    /// area, then shifted in as little as possible.
    public static func place(_ r: GuestRect, in area: GuestRect) -> GuestRect {
        let w = min(r.width, area.width), h = min(r.height, area.height)
        let x = min(max(r.x, area.x), area.maxX - w), y = min(max(r.y, area.y), area.maxY - h)
        return GuestRect(x: x, y: y, width: w, height: h)
    }

    /// QEMU's absolute pointer axes (`usb-tablet`, 0...32767 across the
    /// display) for a guest pixel, clamped to the display.
    public func absoluteAxes(_ g: CGPoint) -> (x: Int, y: Int) {
        func axis(_ v: CGFloat, _ size: Int) -> Int {
            guard size > 1 else { return 0 }
            let n = min(max(v / CGFloat(size - 1), 0), 1)
            return Int((n * 32767).rounded())
        }
        return (axis(g.x, guestWidth), axis(g.y, guestHeight))
    }

    /// The window's part of the scanout texture, normalised 0...1 with the
    /// texture's own origin (top-left): origin and size.
    public func textureRect(for r: GuestRect) -> (u: Double, v: Double, width: Double, height: Double) {
        guard guestWidth > 0, guestHeight > 0 else { return (0, 0, 0, 0) }
        let gw = Double(guestWidth), gh = Double(guestHeight)
        return (Double(r.x) / gw, Double(r.y) / gh, Double(r.width) / gw, Double(r.height) / gh)
    }

    /// Windows 11 rounds window corners by 8 px at 100% (scaled with DPI),
    /// except maximised windows (docs/05 "The Zen window"). Returned in Mac points.
    public func cornerRadius(state: Seemless_V1_WindowShowState, guestDPIScale: CGFloat = 1) -> CGFloat {
        state == .maximized ? 0 : 8 * guestDPIScale * pointsPerPixel
    }
}
