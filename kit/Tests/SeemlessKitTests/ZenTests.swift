import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import SeemlessKit

private func window(_ id: UInt64, _ x: Int32, _ y: Int32, _ w: UInt32, _ h: UInt32,
                    title: String = "Untitled - Notepad", kind: Seemless_V1_WindowKind = .normal,
                    state: Seemless_V1_WindowShowState = .normal, owner: UInt64 = 0) -> Seemless_V1_Window {
    .with {
        $0.id = id
        $0.ownerID = owner
        $0.kind = kind
        $0.rect = .with { $0.x = x; $0.y = y; $0.width = w; $0.height = h }
        $0.title = title
        $0.appKey = "notepad"
        $0.state = state
        $0.flags = .with { $0.resizable = true }
    }
}

@Suite struct ZenWindowModelTests {
    let display = GuestRect(x: 0, y: 0, width: 1280, height: 800)

    @Test func snapshotAddsThenDiffs() {
        var m = ZenWindowModel(bounds: display)
        let first = m.apply(.windowSnapshot(.with { $0.windows = [window(1, 100, 80, 640, 480), window(2, 300, 200, 400, 300)] }))
        #expect(first.count == 2)
        #expect(m.order == [1, 2])
        // A later snapshot replaces everything: 1 unchanged, 2 gone, 3 new.
        let second = m.apply(.windowSnapshot(.with { $0.windows = [window(1, 100, 80, 640, 480), window(3, 0, 0, 200, 100)] }))
        #expect(second.contains(.removed(2)))
        #expect(second.contains { if case .added(let w) = $0 { w.id == 3 } else { false } })
        #expect(!second.contains { if case .updated(let w) = $0 { w.id == 1 } else { false } }, "unchanged windows report nothing")
        #expect(m.order == [1, 3])
    }

    @Test func updatesAreFieldMasked() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowAdded(.with { $0.window = window(1, 100, 80, 640, 480) }))
        // Only the title is listed as changed: the zero rect in the message must be ignored.
        var w = Seemless_V1_Window()
        w.id = 1
        w.title = "notes.txt - Notepad"
        let changes = m.apply(.windowUpdated(.with { $0.window = w; $0.changed = [.title] }))
        guard case .updated(let info)? = changes.first else { Issue.record("no update"); return }
        #expect(info.title == "notes.txt - Notepad")
        #expect(info.rect == GuestRect(x: 100, y: 80, width: 640, height: 480))
        // An update with no real change gives nothing.
        #expect(m.apply(.windowUpdated(.with { $0.window = w; $0.changed = [.title] })).isEmpty)
    }

    @Test func removalAndUnknownIDs() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowAdded(.with { $0.window = window(1, 0, 0, 10, 10) }))
        #expect(m.apply(.windowRemoved(.with { $0.id = 1 })) == [.removed(1)])
        #expect(m.apply(.windowRemoved(.with { $0.id = 1 })).isEmpty)
        #expect(m.apply(.windowUpdated(.with { $0.window = window(9, 0, 0, 1, 1); $0.changed = [.rect] })).isEmpty)
        #expect(m.rejected == 1)
    }

    // The guest is untrusted (docs/06): everything is clamped and capped.

    @Test func rectsAreClampedToTheDisplay() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowAdded(.with { $0.window = window(1, -50, -20, 200, 100) }))
        _ = m.apply(.windowAdded(.with { $0.window = window(2, 1200, 700, .max, .max) }))
        _ = m.apply(.windowAdded(.with { $0.window = window(3, 5000, 5000, 10, 10) }))
        #expect(m.windows[1]?.rect == GuestRect(x: 0, y: 0, width: 150, height: 80))
        #expect(m.windows[2]?.rect == GuestRect(x: 1200, y: 700, width: 80, height: 100))
        #expect(m.windows[3]?.rect.isEmpty == true)
        #expect(m.mirrored.map(\.id) == [1, 2], "an off-screen window is not mirrored")
    }

    @Test func titlesArePlainAndCapped() {
        var m = ZenWindowModel(bounds: display)
        let title = "Evil\u{0007}\u{001B}[31m" + String(repeating: "x", count: 1000)
        _ = m.apply(.windowAdded(.with { $0.window = window(1, 0, 0, 10, 10, title: title) }))
        let t = m.windows[1]!.title
        #expect(t.count == ZenWindowModel.maxTitleLength)
        #expect(!t.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }

    @Test func badIDsAndTooManyWindowsAreRejected() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowAdded(.with { $0.window = window(0, 0, 0, 10, 10) }))
        _ = m.apply(.windowAdded(.with { $0.window = window(5, 0, 0, 10, 10, owner: 5) }))
        #expect(m.windows.isEmpty)
        let many = (1...(ZenWindowModel.maxWindows + 10)).map { window(UInt64($0), 0, 0, 10, 10) }
        _ = m.apply(.windowSnapshot(.with { $0.windows = many }))
        #expect(m.windows.count == ZenWindowModel.maxWindows)
    }

    @Test func onlyAppWindowsAndDialogsAreMirrored() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowSnapshot(.with { $0.windows = [
            window(1, 0, 0, 100, 100),
            window(2, 0, 0, 100, 100, kind: .dialog, owner: 1),
            window(3, 0, 0, 100, 100, kind: .menu),
            window(4, 0, 0, 100, 100, kind: .tooltip),
            window(5, 0, 0, 100, 100, state: .minimized),
        ] }))
        #expect(m.mirrored.map(\.id) == [1, 2])
    }
}

@Suite struct ZenGeometryTests {
    // Guest 1280x800 placed with its top-left at Mac point (100, 900), 1 pt per pixel.
    let g = ZenGeometry(guestWidth: 1280, guestHeight: 800, topLeft: CGPoint(x: 100, y: 900), pointsPerPixel: 1)

    @Test func guestRectsMapToCocoaFrames() {
        let f = g.macFrame(for: GuestRect(x: 10, y: 20, width: 300, height: 200))
        #expect(f == CGRect(x: 110, y: 680, width: 300, height: 200))  // y-up: 900 - 20 - 200
        let half = ZenGeometry(guestWidth: 2560, guestHeight: 1600, topLeft: .zero, pointsPerPixel: 0.5)
        #expect(half.macFrame(for: GuestRect(x: 200, y: 100, width: 400, height: 300))
                == CGRect(x: 100, y: -200, width: 200, height: 150))
    }

    @Test func macPointsRoundTripToGuestPixels() {
        let r = GuestRect(x: 10, y: 20, width: 300, height: 200)
        let f = g.macFrame(for: r)
        // The top-left corner of the Mac frame is the window's guest origin.
        #expect(g.guestPoint(fromMac: CGPoint(x: f.minX, y: f.maxY)) == CGPoint(x: 10, y: 20))
        #expect(g.guestPoint(fromMac: CGPoint(x: f.maxX, y: f.minY)) == CGPoint(x: 310, y: 220))
    }

    @Test func absoluteAxesSpanTheDisplayAndClamp() {
        #expect(g.absoluteAxes(CGPoint(x: 0, y: 0)) == (0, 0))
        #expect(g.absoluteAxes(CGPoint(x: 1279, y: 799)) == (32767, 32767))
        #expect(g.absoluteAxes(CGPoint(x: -40, y: 5000)) == (0, 32767))
        let mid = g.absoluteAxes(CGPoint(x: 639.5, y: 399.5))
        #expect(abs(mid.x - 16384) <= 1 && abs(mid.y - 16384) <= 1)
    }

    @Test func textureRectsAreNormalised() {
        let t = g.textureRect(for: GuestRect(x: 640, y: 200, width: 320, height: 400))
        #expect(t.u == 0.5 && t.v == 0.25 && t.width == 0.25 && t.height == 0.5)
    }

    @Test func cornersFollowWindows11() {
        #expect(g.cornerRadius(state: .normal) == 8)
        #expect(g.cornerRadius(state: .maximized) == 0)
        let retina = ZenGeometry(guestWidth: 2560, guestHeight: 1600, topLeft: .zero, pointsPerPixel: 0.5)
        #expect(retina.cornerRadius(state: .normal, guestDPIScale: 2) == 8)
    }
}

@Suite struct GuestInputTests {
    @Test func keyMapCoversTheBasicsAndIsUnique() {
        #expect(GuestKeyMap.qcode(forKeyCode: kVK_ANSI_A) == "a")
        #expect(GuestKeyMap.qcode(forKeyCode: kVK_Return) == "ret")
        #expect(GuestKeyMap.qcode(forKeyCode: kVK_Command) == "meta_l")
        #expect(GuestKeyMap.qcode(forKeyCode: kVK_F12) == "f12")
        let values = Array(GuestKeyMap.qcodes.values)
        #expect(Set(values).count == values.count, "two Mac keys must not send the same PC key")
        #expect(GuestKeyMap.isModifier("shift") && !GuestKeyMap.isModifier("a"))
    }

    @Test func eventsEncodeAsQMPInputEvents() throws {
        let key = GuestInputEvent.key(qcode: "a", down: true).qmp
        #expect(key == [.object(["type": "key", "data": .object(["down": true, "key": .object(["type": "qcode", "data": "a"])])])])
        let abs = GuestInputEvent.absolute(x: 10, y: 20).qmp
        #expect(abs.count == 2)
        #expect(abs[1]["data"]?["axis"]?.stringValue == "y" && abs[1]["data"]?["value"]?.intValue == 20)
        #expect(GuestInputEvent.wheel(deltaY: 3) == [.button("wheel-up", down: true), .button("wheel-up", down: false)])
        #expect(GuestInputEvent.wheel(deltaY: 0).isEmpty)
        #expect(GuestInputEvent.buttonName(1) == "right" && GuestInputEvent.buttonName(9) == nil)
    }
}

@Suite struct ZenWindowBehaviorTests {
    @Test func hitTestCodesMapToHostActions() {
        typealias C = ZenHitArea.Code
        #expect(ZenHitArea(hitTestCode: C.caption) == .caption)
        #expect(ZenHitArea(hitTestCode: C.bottomRight) == .resize([.bottom, .right]))
        #expect(ZenHitArea(hitTestCode: C.topLeft) == .resize([.top, .left]))
        for code in [C.client, C.close, C.minButton, C.maxButton, C.sysMenu, 0, 999] {
            #expect(ZenHitArea(hitTestCode: code) == .passThrough, "\(code) goes to the guest")
        }
    }

    @Test func resizingKeepsTheOppositeEdgesAndAMinimum() {
        let r = GuestRect(x: 100, y: 100, width: 400, height: 300)
        #expect(r.resized([.right, .bottom], dx: 50, dy: -20) == GuestRect(x: 100, y: 100, width: 450, height: 280))
        #expect(r.resized([.left], dx: 30, dy: 0) == GuestRect(x: 130, y: 100, width: 370, height: 300))
        #expect(r.resized([.top, .left], dx: 1000, dy: 1000) == GuestRect(x: 340, y: 320, width: 160, height: 80))
    }

    @Test func simulatedWindowsBehaveLikeWindows() {
        var wm = SimulatedWindowManager(workArea: GuestRect(x: 0, y: 0, width: 800, height: 560))
        wm.observe(.windowSnapshot(.with { $0.windows = [window(1, 100, 100, 400, 300)] }))
        func hit(_ x: Int32, _ y: Int32) -> Int32 {
            guard case .hitTestResult(let r)? = wm.handle(.hitTest(.with { $0.id = 1; $0.point = .with { $0.x = x; $0.y = y } }))?.reply
            else { return -1 }
            return r.code
        }
        typealias C = ZenHitArea.Code
        #expect(hit(200, 110) == C.caption)
        #expect(hit(490, 110) == C.close)       // rightmost 46 px of the caption
        #expect(hit(430, 110) == C.maxButton)
        #expect(hit(380, 110) == C.minButton)
        #expect(hit(300, 250) == C.client)
        #expect(hit(102, 250) == C.left)
        #expect(hit(498, 398) == C.bottomRight)
        #expect(hit(10, 10) == 0)

        // Maximise fills the work area; restore brings the old rect back.
        guard case .windowUpdated(let max)? = wm.handle(.windowCommand(.with { $0.id = 1; $0.cmd = .maximize }))?.events.first
        else { Issue.record("no update"); return }
        #expect(max.window.state == .maximized && max.window.rect.width == 800 && max.window.rect.height == 560)
        #expect(hit(102, 250) == C.client, "a maximised window has no resize border")
        guard case .windowUpdated(let restored)? = wm.handle(.windowCommand(.with { $0.id = 1; $0.cmd = .restore }))?.events.first
        else { Issue.record("no update"); return }
        #expect(restored.window.state == .normal && restored.window.rect.x == 100 && restored.window.rect.width == 400)

        // Moves and closes are reported.
        let moved = wm.handle(.setWindowRect(.with { $0.id = 1; $0.rect = .with { $0.x = 5; $0.y = 6; $0.width = 400; $0.height = 300 } }))
        #expect(moved?.reply == .ack(.init()))
        let closed = wm.handle(.windowCommand(.with { $0.id = 1; $0.cmd = .close }))
        #expect(closed?.events == [.windowRemoved(.with { $0.id = 1 })])
        #expect(wm.handle(.windowCommand(.with { $0.id = 1; $0.cmd = .minimize })) == nil, "gone windows are unknown")
    }

    @Test func mockAgentRunsTheWindowManagerOverTheWire() async throws {
        let dir = URL(filePath: "/tmp/slz-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appending(path: "a.sock")
        let script = try JSONDecoder().decode(MockAgentScript.self, from: Data("""
            {"windowManager": {"width": 800, "height": 600},
             "steps": [{"send": {"windowSnapshot": {"windows": [{"id": "7", "kind": "WINDOW_KIND_NORMAL",
                 "rect": {"x": 50, "y": 50, "width": 300, "height": 200}, "state": "WINDOW_SHOW_STATE_NORMAL"}]}}}]}
            """.utf8))
        let mock = MockAgent(script: script)
        let server = Task { try await mock.serve(socket: socket) }
        let client = try await AgentClient.connect(socket: socket, connectTimeout: .seconds(5))
        var events = client.events.makeAsyncIterator()
        _ = await events.next()  // the snapshot
        let hit = try await client.request(.hitTest(.with { $0.id = 7; $0.point = .with { $0.x = 100; $0.y = 60 } }))
        guard case .hitTestResult(let r) = hit.body else { Issue.record("got \(hit.bodyName)"); return }
        #expect(ZenHitArea(hitTestCode: r.code) == .caption)
        let ack = try await client.request(.windowCommand(.with { $0.id = 7; $0.cmd = .minimize }))
        #expect(ack.bodyName == "ack")
        let update = try #require(await events.next())
        guard case .windowUpdated(let u) = update.body else { Issue.record("got \(update.bodyName)"); return }
        #expect(u.window.state == .minimized)
        await client.close()
        try await server.value
    }
}

// Found in the Zen bug-testing round (docs/testing/seamless.md, 2026-11-24).
@Suite struct ZenBugRoundTests {
    let display = GuestRect(x: 0, y: 0, width: 800, height: 600)
    let g = ZenGeometry(guestWidth: 800, guestHeight: 600, topLeft: CGPoint(x: 100, y: 900), pointsPerPixel: 1)

    @Test func partlyOffscreenWindowsKeepTheirFullRect() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowAdded(.with { $0.window = window(1, -100, 400, 250, 300) }))
        let w = m.windows[1]!
        #expect(w.rect == GuestRect(x: 0, y: 400, width: 150, height: 200))
        #expect(w.fullRect == GuestRect(x: -100, y: 400, width: 250, height: 300))
        // A field-masked rect update keeps both in step.
        _ = m.apply(.windowUpdated(.with { $0.window = window(1, 700, -50, 300, 100); $0.changed = [.rect] }))
        #expect(m.windows[1]?.rect == GuestRect(x: 700, y: 0, width: 100, height: 50))
        #expect(m.windows[1]?.fullRect == GuestRect(x: 700, y: -50, width: 300, height: 100))
        // Hostile values are capped, so arithmetic on them cannot overflow.
        _ = m.apply(.windowAdded(.with { $0.window = window(2, .min, .max, .max, .max) }))
        #expect(m.windows[2]?.fullRect == GuestRect(x: -ZenWindowModel.maxCoordinate, y: ZenWindowModel.maxCoordinate,
                                                   width: ZenWindowModel.maxCoordinate, height: ZenWindowModel.maxCoordinate))
    }

    @Test func aDisplayResizeClipsWindowsAgain() {
        var m = ZenWindowModel(bounds: display)
        _ = m.apply(.windowSnapshot(.with { $0.windows = [window(1, 600, 400, 400, 300), window(2, 10, 10, 100, 100)] }))
        #expect(m.windows[1]?.rect == GuestRect(x: 600, y: 400, width: 200, height: 200))
        // Bigger display: window 1 is whole again; window 2 did not change.
        let grow = m.setBounds(GuestRect(x: 0, y: 0, width: 1280, height: 800))
        #expect(grow.count == 1)
        #expect(m.windows[1]?.rect == GuestRect(x: 600, y: 400, width: 400, height: 300))
        // Smaller: window 1 is off the display, so no longer mirrored.
        _ = m.setBounds(GuestRect(x: 0, y: 0, width: 640, height: 400))
        #expect(m.windows[1]?.rect.isEmpty == true)
        #expect(m.mirrored.map(\.id) == [2])
        #expect(m.setBounds(GuestRect(x: 0, y: 0, width: 640, height: 400)).isEmpty)
    }

    @Test func hoverHitTestsArePaced() {
        var t = HoverHitTestThrottle()
        let p = CGPoint(x: 100, y: 10)
        #expect(t.pointerMoved(to: p, now: 0, cachedAt: nil) == .sendNow)
        // One in flight at a time.
        #expect(t.pointerMoved(to: CGPoint(x: 120, y: 10), now: 0.01, cachedAt: nil) == .retry(after: HoverHitTestThrottle.retryDelay))
        t.requestFinished()
        // Answered, and the pointer is still near the answer: nothing to ask.
        #expect(t.pointerMoved(to: CGPoint(x: 102, y: 11), now: 0.02, cachedAt: p) == .skip)
        // Moving on, but sooner than the interval: try again when it has passed.
        guard case .retry(let after) = t.pointerMoved(to: CGPoint(x: 150, y: 10), now: 0.04, cachedAt: p) else {
            Issue.record("expected a retry"); return
        }
        #expect(abs(after - 0.06) < 1e-9)
        #expect(t.pointerMoved(to: CGPoint(x: 150, y: 10), now: 0.1, cachedAt: p) == .sendNow)
        // A pointer moving continuously for a minute at 120 Hz asks at most 10 times a second.
        var u = HoverHitTestThrottle(), sent = 0
        for i in 0..<(120 * 60) {
            let now = Double(i) / 120
            if u.pointerMoved(to: CGPoint(x: Double(i), y: 5), now: now, cachedAt: nil) == .sendNow { sent += 1; u.requestFinished() }
        }
        #expect(sent <= 601 && sent >= 500, "\(sent) requests")
        #expect(HoverHitTestThrottle.trusts(p, for: CGPoint(x: 106, y: 4)))
        #expect(!HoverHitTestThrottle.trusts(p, for: CGPoint(x: 107, y: 10)))
    }

    @Test func capsLockIsAFullPressAndSidesAreSeparate() {
        // Caps Lock on, then off: each change is down + up, so the guest toggles twice too.
        let on = GuestKeyMap.modifierEvents(keyCode: kVK_CapsLock, flags: 1 << 16)
        let off = GuestKeyMap.modifierEvents(keyCode: kVK_CapsLock, flags: 0)
        #expect(on == [.key(qcode: "caps_lock", down: true), .key(qcode: "caps_lock", down: false)])
        #expect(off == on)
        // Left shift held (0x02), right shift released: right goes up, not down.
        let shiftFlag: UInt = 0x20000
        #expect(GuestKeyMap.modifierEvents(keyCode: kVK_RightShift, flags: shiftFlag | 0x02) == [.key(qcode: "shift_r", down: false)])
        #expect(GuestKeyMap.modifierEvents(keyCode: kVK_Shift, flags: shiftFlag | 0x02) == [.key(qcode: "shift", down: true)])
        #expect(GuestKeyMap.modifierEvents(keyCode: kVK_Command, flags: 0x100000 | 0x08) == [.key(qcode: "meta_l", down: true)])
        #expect(GuestKeyMap.modifierEvents(keyCode: kVK_RightOption, flags: 0) == [.key(qcode: "alt_r", down: false)])
        #expect(GuestKeyMap.modifierEvents(keyCode: kVK_ANSI_A, flags: 0).isEmpty)
    }

    @Test func trackpadScrollingIsAccumulated() {
        var s = ScrollAccumulator()
        // A mouse wheel: one line is one click.
        #expect(s.clicks(deltaX: 0, deltaY: 1, precise: false) == (0, 1))
        #expect(s.clicks(deltaX: 0, deltaY: -0.1, precise: false) == (0, -1))
        // A trackpad: 30 events of 2 pt are 60 pt, i.e. 2 clicks, not 30.
        var total = 0
        for _ in 0..<30 { total += s.clicks(deltaX: 0, deltaY: 2, precise: true).y }
        #expect(total == 2)
        s.reset()
        #expect(s.clicks(deltaX: -50, deltaY: 0, precise: true) == (-2, 0))
        // Clicks become wheel buttons, capped per event.
        #expect(GuestInputEvent.wheel(clicksY: 1) == [.button("wheel-up", down: true), .button("wheel-up", down: false)])
        #expect(GuestInputEvent.wheel(clicksX: -1) == [.button("wheel-right", down: true), .button("wheel-right", down: false)])
        #expect(GuestInputEvent.wheel(clicksY: -500).count == 2 * ScrollAccumulator.maxClicksPerEvent)
    }
}

// Owner, 2026-11-24: moving a Zen window moves only the Mac window.
@Suite struct ZenMacPlacementTests {
    let g = ZenGeometry(guestWidth: 1024, guestHeight: 768, topLeft: CGPoint(x: 40, y: 950), pointsPerPixel: 1)
    let notepad = GuestRect(x: 161, y: 156, width: 758, height: 514)

    @Test func aMacMoveIsAnOffsetAndInputFollowsIt() {
        let plain = g.macFrame(for: notepad)
        #expect(g.macFrame(for: notepad, offset: .zero) == plain)
        // The user drags the window 300 pt right and 120 pt down on the Mac.
        let moved = plain.offsetBy(dx: 300, dy: -120)
        let off = g.offset(placing: notepad, at: moved)
        #expect(off == CGVector(dx: 300, dy: -120))
        #expect(g.macFrame(for: notepad, offset: off) == moved)
        // A click on the moved window's top-left pixel is Notepad's top-left in the guest.
        #expect(g.guestPoint(fromMac: CGPoint(x: moved.minX, y: moved.maxY), offset: off) == CGPoint(x: 161, y: 156))
        // The guest later moves the window by itself: the Mac window moves by the same amount.
        let guestMoved = GuestRect(x: 200, y: 100, width: 758, height: 514)
        #expect(g.macFrame(for: guestMoved, offset: off) == moved.offsetBy(dx: 39, dy: 56))
        // A resize that keeps the top-left keeps the offset.
        let bigger = GuestRect(x: 161, y: 156, width: 900, height: 600)
        #expect(g.offset(placing: bigger, at: g.macFrame(for: bigger, offset: off)) == off)
    }

    @Test func withoutAnAgentTheStandardCaptionStillDrags() {
        typealias A = ZenHitArea
        #expect(A.standardFrame(at: CGPoint(x: 400, y: 170), window: notepad) == .caption)
        #expect(A.standardFrame(at: CGPoint(x: 400, y: 200), window: notepad) == .passThrough, "below the caption: client")
        #expect(A.standardFrame(at: CGPoint(x: 900, y: 170), window: notepad) == .passThrough, "the close button")
        #expect(A.standardFrame(at: CGPoint(x: 100, y: 170), window: notepad) == .passThrough, "outside the window")
        #expect(A.standardFrame(at: CGPoint(x: 400, y: 215), window: notepad, dpiScale: 2) == .caption, "200%: a 64 px caption")
    }
}

// Owner, 2026-11-24: a live resize re-lays the guest window out, never stretches it.
@Suite struct ZenLiveResizeTests {
    @Test func cropsAreDrawnOneToOneFromTheTopLeft() {
        let crop = (u: 0.25, v: 0.5, width: 0.5, height: 0.25)
        // The view grew past the content: content drawn at its own size, rest is background.
        let grown = ZenGeometry.fit(crop: crop, content: CGSize(width: 400, height: 300), view: CGSize(width: 500, height: 350))
        #expect(grown.size == CGSize(width: 400, height: 300))
        #expect(grown.crop.width == 0.5 && grown.crop.height == 0.25)
        // The view shrank below it: the crop is cut, not squeezed.
        let shrunk = ZenGeometry.fit(crop: crop, content: CGSize(width: 400, height: 300), view: CGSize(width: 200, height: 300))
        #expect(shrunk.size == CGSize(width: 200, height: 300))
        #expect(shrunk.crop.u == 0.25 && shrunk.crop.width == 0.25 && shrunk.crop.height == 0.25)
        #expect(ZenGeometry.fit(crop: crop, content: .zero, view: CGSize(width: 10, height: 10)).size == .zero)
    }

    @Test func liveResizeRequestsArePaced() {
        var p = LiveResizePacer()
        #expect(p.sizeChanged(now: 0) == .sendNow)
        guard case .sendAfter(let d) = p.sizeChanged(now: 0.01) else { Issue.record("expected a scheduled send"); return }
        #expect(abs(d - 0.04) < 1e-9)
        #expect(p.sizeChanged(now: 0.02) == .alreadyScheduled)
        p.scheduledSendRan(now: 0.05)
        #expect(p.sizeChanged(now: 0.2) == .sendNow)
        // A 2-second live resize with 120 events a second sends about 40 requests.
        var q = LiveResizePacer(), sent = 0, due: Double?
        for i in 0..<240 {
            let now = Double(i) / 120
            if let t = due, now >= t { q.scheduledSendRan(now: now); sent += 1; due = nil }
            switch q.sizeChanged(now: now) {
            case .sendNow: sent += 1
            case .sendAfter(let d): due = now + d
            case .alreadyScheduled: break
            }
        }
        #expect(sent >= 35 && sent <= 42, "\(sent)")
    }
}

// The Zen stand-in helper bridge (proto/mock/zen-guest-helper.ps1), 2026-11-24.
@Suite struct GuestHelperBridgeTests {
    @Test func helperLinesAreParsedAndValidated() {
        #expect(GuestHelperMessage.parse("rect 6619 174 159 758 525 normal")
                == .window(id: 6619, rect: GuestRect(x: 174, y: 159, width: 758, height: 525), state: .normal))
        #expect(GuestHelperMessage.parse("rect 6619 -8 -8 1040 784 max\r\n")
                == .window(id: 6619, rect: GuestRect(x: -8, y: -8, width: 1040, height: 784), state: .maximized))
        #expect(GuestHelperMessage.parse("title 6619 notes.txt - Notepad") == .title(id: 6619, "notes.txt - Notepad"))
        #expect(GuestHelperMessage.parse("gone 6619") == .gone(6619))
        // The guest is untrusted: malformed, out-of-range or oversized lines are dropped.
        for bad in ["rect 0 1 1 1 1 normal", "rect 5 1 1 -1 1 normal", "rect 5 1 1 1 1 huge", "rect 5 1 1 1 normal",
                    "rect 5 99999999 1 1 1 normal", "gone 5 extra", "jump 5", "", "title x y",
                    "title 5 " + String(repeating: "a", count: 2000)] {
            #expect(GuestHelperMessage.parse(bad) == nil, "\(bad.prefix(30))")
        }
        #expect(GuestHelperMessage.setLine(id: 9, rect: GuestRect(x: 1, y: 2, width: 3, height: 4).protoRect) == "set 9 1 2 3 4\n")
        #expect(GuestHelperMessage.commandLine(id: 9, .maximize) == "cmd 9 max\n")
    }

    @Test func helperWindowsBecomeAgentEvents() {
        var h = GuestHelperWindows()
        guard case .windowAdded(let a)? = h.apply(.window(id: 3, rect: GuestRect(x: 1, y: 2, width: 30, height: 40), state: .normal)) else {
            Issue.record("expected windowAdded"); return
        }
        #expect(a.window.kind == .normal)
        guard case .windowUpdated(let u)? = h.apply(.title(id: 3, "Untitled - Notepad")) else { Issue.record("expected an update"); return }
        #expect(u.changed == [.title] && u.window.title == "Untitled - Notepad")
        #expect(h.apply(.title(id: 4, "unknown")) == nil)
        guard case .windowSnapshot(let s) = h.snapshot else { Issue.record("expected a snapshot"); return }
        #expect(s.windows.map(\.id) == [3])
        #expect(h.apply(.gone(3)) == .windowRemoved(.with { $0.id = 3 }))
        #expect(h.apply(.gone(3)) == nil)
    }

    @Test func theMockPassesHelperWindowsAndRequestsThrough() async throws {
        let dir = URL(filePath: "/tmp/slh-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appending(path: "a.sock")
        let port = UInt16.random(in: 47000...48999)
        let mock = MockAgent(script: try JSONDecoder().decode(MockAgentScript.self, from: Data("{\"guestHelper\": {\"port\": \(port)}}".utf8)))
        let server = Task { try await mock.serve(socket: socket) }
        // The helper (a TCP client standing in for the PowerShell script) reports Notepad first.
        var helperFD: Int32 = -1
        for _ in 0..<50 {
            let fd = socket_tcp(port)
            if fd >= 0 { helperFD = fd; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(helperFD >= 0)
        defer { close(helperFD) }
        send(helperFD, "rect 77 174 159 758 525 normal\ntitle 77 Untitled - Notepad\n")
        try await Task.sleep(for: .milliseconds(200))
        let client = try await AgentClient.connect(socket: socket, connectTimeout: .seconds(5))
        var events = client.events.makeAsyncIterator()
        let snap = try #require(await events.next())
        guard case .windowSnapshot(let s) = snap.body else { Issue.record("got \(snap.bodyName)"); return }
        #expect(s.windows.first?.title == "Untitled - Notepad")
        #expect(s.windows.first?.rect.width == 758)
        // The host resizes it: the helper gets the request; its next report reaches the host.
        let ack = try await client.request(.setWindowRect(.with { $0.id = 77; $0.rect = GuestRect(x: 174, y: 159, width: 900, height: 600).protoRect }))
        #expect(ack.bodyName == "ack")
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(helperFD, &buf, buf.count)
        #expect(String(decoding: buf[0..<max(0, n)], as: UTF8.self) == "set 77 174 159 900 600\n")
        send(helperFD, "rect 77 174 159 900 600 normal\n")
        let upd = try #require(await events.next())
        guard case .windowUpdated(let u) = upd.body else { Issue.record("got \(upd.bodyName)"); return }
        #expect(u.window.rect.width == 900)
        await client.close()
        try await server.value
    }

    private func socket_tcp(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { close(fd); return -1 }
        return fd
    }

    private func send(_ fd: Int32, _ s: String) {
        let b = Array(s.utf8)
        _ = b.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

// Testing on zen1 (2026-11-24): a Notepad resized taller than the guest's work
// area slid under the taskbar, which then showed in the Zen window.
@Suite struct ZenWorkAreaTests {
    let area = ZenGeometry(guestWidth: 1024, guestHeight: 768, topLeft: .zero, pointsPerPixel: 1).assumedWorkArea

    @Test func guestWindowsAreKeptInTheWorkArea() {
        #expect(area == GuestRect(x: 0, y: 0, width: 1024, height: 720))
        // Taller than fits below its top: moved up, same size.
        #expect(ZenGeometry.place(GuestRect(x: 174, y: 159, width: 758, height: 700), in: area)
                == GuestRect(x: 174, y: 20, width: 758, height: 700))
        // Bigger than the work area: shrunk to it.
        #expect(ZenGeometry.place(GuestRect(x: 174, y: 159, width: 1400, height: 900), in: area)
                == GuestRect(x: 0, y: 0, width: 1024, height: 720))
        // Off the left or top: pulled in. Already inside: untouched.
        #expect(ZenGeometry.place(GuestRect(x: -30, y: -5, width: 200, height: 100), in: area) == GuestRect(x: 0, y: 0, width: 200, height: 100))
        let inside = GuestRect(x: 10, y: 10, width: 300, height: 200)
        #expect(ZenGeometry.place(inside, in: area) == inside)
    }
}

@Suite struct ZenLastWindowWatchTests {
    @Test func firesAfterTheLastWindowClosesAndStaysClosed() {
        var w = ZenLastWindowWatch(delay: 0.3)
        #expect(w.update(hasOpenWindows: true, now: 0) == .none)
        #expect(w.update(hasOpenWindows: false, now: 1) == .checkAfter(0.3))
        #expect(w.update(hasOpenWindows: false, now: 1.1) == .none, "one timer is enough")
        #expect(!w.shouldSwitch(hasOpenWindows: false, now: 1.2), "too early")
        #expect(w.shouldSwitch(hasOpenWindows: false, now: 1.3))
    }

    @Test func neverFiresWhenZenStartsEmpty() {
        var w = ZenLastWindowWatch()
        #expect(w.update(hasOpenWindows: false, now: 0) == .none)
        #expect(!w.shouldSwitch(hasOpenWindows: false, now: 10))
    }

    @Test func aNewWindowWithinTheDelayCancels() {
        var w = ZenLastWindowWatch(delay: 0.3)
        _ = w.update(hasOpenWindows: true, now: 0)
        _ = w.update(hasOpenWindows: false, now: 1)        // splash screen closed
        #expect(w.update(hasOpenWindows: true, now: 1.1) == .none)  // main window opened
        #expect(!w.shouldSwitch(hasOpenWindows: true, now: 1.3))
        #expect(!w.shouldSwitch(hasOpenWindows: false, now: 1.3), "cancelled: needs a new empty period")
        #expect(w.update(hasOpenWindows: false, now: 2) == .checkAfter(0.3))
        #expect(w.shouldSwitch(hasOpenWindows: false, now: 2.3))
    }

    @Test func resetForgetsWindows() {
        var w = ZenLastWindowWatch()
        _ = w.update(hasOpenWindows: true, now: 0)
        w.reset()
        #expect(w.update(hasOpenWindows: false, now: 1) == .none)
    }

    @Test func minimisedWindowsCountAsOpen() {
        var m = ZenWindowModel(bounds: GuestRect(x: 0, y: 0, width: 1280, height: 800))
        _ = m.apply(.windowSnapshot(.with { $0.windows = [window(1, 100, 80, 640, 480), window(2, 0, 0, 200, 100, kind: .tooltip)] }))
        #expect(m.hasOpenAppWindows)
        _ = m.apply(.windowUpdated(.with {
            $0.window = .with { $0.id = 1; $0.state = .minimized }
            $0.changed = [.state]
        }))
        #expect(m.mirrored.isEmpty)
        #expect(m.hasOpenAppWindows, "minimised: the app still runs")
        _ = m.apply(.windowRemoved(.with { $0.id = 1 }))
        #expect(!m.hasOpenAppWindows, "a tooltip alone is not an app window")
    }
}
