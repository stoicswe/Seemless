import CoreGraphics
import Testing
@testable import SeemlessKit

@Suite struct DesktopGeometryTests {
    let g = DesktopGeometry(guestWidth: 1024, guestHeight: 768)!

    @Test func rejectsEmptyDisplay() {
        #expect(DesktopGeometry(guestWidth: 0, guestHeight: 768) == nil)
        #expect(DesktopGeometry(guestWidth: 1024, guestHeight: -1) == nil)
    }

    @Test func fillsAViewOfTheSameRatio() {
        #expect(g.drawRect(in: CGSize(width: 512, height: 384)) == CGRect(x: 0, y: 0, width: 512, height: 384))
    }

    @Test func barsWhenTheRatioDiffers() {
        // Wider view: bars left and right.
        #expect(g.drawRect(in: CGSize(width: 1200, height: 600)) == CGRect(x: 200, y: 0, width: 800, height: 600))
        // Taller view: bars top and bottom.
        #expect(g.drawRect(in: CGSize(width: 400, height: 600)) == CGRect(x: 0, y: 150, width: 400, height: 300))
        #expect(g.drawRect(in: .zero) == .zero)
    }

    @Test func mapsViewPointsToGuestPixels() {
        let view = CGSize(width: 512, height: 384)          // half size
        #expect(g.guestPoint(fromView: CGPoint(x: 256, y: 192), viewSize: view) == CGPoint(x: 512, y: 384))
        #expect(g.guestPoint(fromView: .zero, viewSize: view) == .zero)
        // Bars and outside points clamp to the display.
        let wide = CGSize(width: 1200, height: 600)
        #expect(g.guestPoint(fromView: CGPoint(x: 50, y: 300), viewSize: wide) == CGPoint(x: 0, y: 384))
        #expect(g.guestPoint(fromView: CGPoint(x: 5000, y: -10), viewSize: wide) == CGPoint(x: 1023, y: 0))
    }

    @Test func absoluteAxesSpanTheDisplay() {
        let view = CGSize(width: 1024, height: 768)
        #expect(g.absoluteAxes(fromView: .zero, viewSize: view) == (x: 0, y: 0))
        #expect(g.absoluteAxes(fromView: CGPoint(x: 2000, y: 2000), viewSize: view) == (x: 32767, y: 32767))
        // Letterboxed: the centre of the view is the centre of the display.
        let a = g.absoluteAxes(fromView: CGPoint(x: 600, y: 300), viewSize: CGSize(width: 1200, height: 600))
        #expect(abs(a.x - 16399) <= 16 && abs(a.y - 16405) <= 16)
    }

    @Test func initialSizeFitsTheScreen() {
        #expect(g.initialContentSize(pointsPerPixel: 1, fitting: CGSize(width: 1440, height: 900)) == CGSize(width: 1024, height: 768))
        // Too tall: shrunk, ratio kept.
        #expect(g.initialContentSize(pointsPerPixel: 1, fitting: CGSize(width: 1440, height: 600)) == CGSize(width: 800, height: 600))
    }

    @Test func resolutionChangeKeepsWidth() {
        var h = g
        let changed = h.update(guestWidth: 1280, guestHeight: 800)
        let again = h.update(guestWidth: 1280, guestHeight: 800)
        let empty = h.update(guestWidth: 0, guestHeight: 800)
        #expect(changed)
        #expect(!again, "no change")
        #expect(!empty, "empty sizes are ignored")
        #expect(h.guestWidth == 1280)
        #expect(h.contentSize(resizing: CGSize(width: 1024, height: 768), fitting: CGSize(width: 1440, height: 900))
                == CGSize(width: 1024, height: 640))
        #expect(h.contentSize(resizing: CGSize(width: 1600, height: 1200), fitting: CGSize(width: 1440, height: 900))
                == CGSize(width: 1440, height: 900))
    }
}
