import CoreGraphics
import Foundation

/// Geometry of the desktop window (WP3.2): the whole of scanout 0 shown in
/// one ordinary, resizable Mac window, aspect ratio kept.
///
/// View coordinates are points with the origin at the view's top-left
/// (a flipped view), like guest pixels.
public struct DesktopGeometry: Sendable, Equatable {
    /// Guest display size in pixels (at least 1×1).
    public private(set) var guestWidth: Int
    public private(set) var guestHeight: Int

    /// Nil for an empty display (a scanout that is not set up yet).
    public init?(guestWidth: Int, guestHeight: Int) {
        guard guestWidth > 0, guestHeight > 0 else { return nil }
        self.guestWidth = guestWidth
        self.guestHeight = guestHeight
    }

    public var aspectRatio: CGSize { CGSize(width: guestWidth, height: guestHeight) }

    /// Where the scanout is drawn in a view of `view` size: as large as fits,
    /// aspect kept, centred (bars where the window's ratio differs, e.g.
    /// for a moment after the guest changed resolution).
    public func drawRect(in view: CGSize) -> CGRect {
        guard view.width > 0, view.height > 0 else { return .zero }
        let scale = min(view.width / CGFloat(guestWidth), view.height / CGFloat(guestHeight))
        let w = CGFloat(guestWidth) * scale, h = CGFloat(guestHeight) * scale
        return CGRect(x: (view.width - w) / 2, y: (view.height - h) / 2, width: w, height: h)
    }

    /// The guest pixel under a view point, clamped to the display (a point
    /// on a bar maps to the nearest edge).
    public func guestPoint(fromView p: CGPoint, viewSize: CGSize) -> CGPoint {
        let r = drawRect(in: viewSize)
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (p.x - r.minX) / r.width * CGFloat(guestWidth)
        let y = (p.y - r.minY) / r.height * CGFloat(guestHeight)
        return CGPoint(x: min(max(x, 0), CGFloat(guestWidth - 1)), y: min(max(y, 0), CGFloat(guestHeight - 1)))
    }

    /// QEMU absolute pointer axes (0...32767) for a view point.
    public func absoluteAxes(fromView p: CGPoint, viewSize: CGSize) -> (x: Int, y: Int) {
        ZenGeometry.absoluteAxes(guestPoint(fromView: p, viewSize: viewSize),
                                 guestWidth: guestWidth, guestHeight: guestHeight)
    }

    /// Window content size for a new window: the guest at `pointsPerPixel`,
    /// scaled down (aspect kept) to fit `available` (the screen's usable area).
    public func initialContentSize(pointsPerPixel: CGFloat, fitting available: CGSize) -> CGSize {
        let w = CGFloat(guestWidth) * pointsPerPixel, h = CGFloat(guestHeight) * pointsPerPixel
        return Self.fit(CGSize(width: w, height: h), in: available)
    }

    /// The content size after the guest changed resolution: the window keeps
    /// its width and takes the new aspect ratio, shrunk to fit `available`.
    public func contentSize(resizing current: CGSize, fitting available: CGSize) -> CGSize {
        let w = max(current.width, 1)
        return Self.fit(CGSize(width: w, height: w * CGFloat(guestHeight) / CGFloat(guestWidth)), in: available)
    }

    /// Records a new display size. False (and unchanged) for an empty size
    /// or no change.
    public mutating func update(guestWidth w: Int, guestHeight h: Int) -> Bool {
        guard w > 0, h > 0, w != guestWidth || h != guestHeight else { return false }
        guestWidth = w
        guestHeight = h
        return true
    }

    private static func fit(_ size: CGSize, in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return size }
        let s = min(1, available.width / size.width, available.height / size.height)
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }
}
