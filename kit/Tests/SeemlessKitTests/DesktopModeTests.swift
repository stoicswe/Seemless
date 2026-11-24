import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import SeemlessKit

/// WP3.2 / WP3.4 / WP3.5: keyboard translation, guest resize requests,
/// display preferences, driver lookup and the first-run checklist.
@Suite struct KeyboardTranslatorTests {
    // Raw modifier flags as AppKit reports them (device bit + generic bit).
    let cmdLeft: UInt = 0x0008 | (1 << 20)
    let cmdRight: UInt = 0x0010 | (1 << 20)
    let shiftLeft: UInt = 0x0002 | (1 << 17)

    func key(_ q: String, _ down: Bool) -> GuestInputEvent { .key(qcode: q, down: down) }

    @Test func plainTypingPassesThrough() {
        var t = KeyboardTranslator()
        #expect(t.keyDown(keyCode: kVK_ANSI_H) == [key("h", true)])
        #expect(t.keyUp(keyCode: kVK_ANSI_H) == [key("h", false)])
        #expect(t.flagsChanged(keyCode: kVK_Shift, flags: shiftLeft) == [key("shift", true)])
        #expect(t.keyDown(keyCode: kVK_ANSI_1) == [key("1", true)])
        #expect(t.flagsChanged(keyCode: kVK_Shift, flags: 0) == [key("shift", false)])
    }

    @Test func commandShortcutBecomesCtrlInMacStyle() {
        var t = KeyboardTranslator(style: .mac)
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft) == [])
        #expect(t.keyDown(keyCode: kVK_ANSI_C) == [key("ctrl_r", true), key("c", true)])
        #expect(t.keyUp(keyCode: kVK_ANSI_C) == [key("c", false)])
        // Second shortcut while Cmd is still held: Ctrl is already down.
        #expect(t.keyDown(keyCode: kVK_ANSI_V) == [key("v", true)])
        // AppKit drops key-ups while Cmd is down: released with Cmd.
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: 0) == [key("v", false), key("ctrl_r", false)])
    }

    @Test func repeatedShortcutWithoutKeyUpReleasesFirst() {
        var t = KeyboardTranslator()
        _ = t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft)
        _ = t.keyDown(keyCode: kVK_ANSI_Z)
        #expect(t.keyDown(keyCode: kVK_ANSI_Z) == [key("z", false), key("z", true)])
    }

    @Test func loneCommandTapIsTheWindowsKey() {
        var t = KeyboardTranslator()
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft) == [])
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: 0) == [key("meta_l", true), key("meta_l", false)])
    }

    @Test func reservedShortcutDoesNotTapWindows() {
        var t = KeyboardTranslator()
        _ = t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft)
        #expect(KeyboardTranslator.isReservedForMac(keyCode: kVK_ANSI_H, flags: cmdLeft))
        t.noteReservedShortcut()
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: 0) == [])
    }

    @Test func commandArrowsAreLineAndDocumentEnds() {
        var t = KeyboardTranslator()
        _ = t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft)
        #expect(t.keyDown(keyCode: kVK_LeftArrow) == [key("home", true)])
        #expect(t.keyUp(keyCode: kVK_LeftArrow) == [key("home", false)])
        #expect(t.keyDown(keyCode: kVK_DownArrow) == [key("ctrl_r", true), key("end", true)])
        #expect(t.keyUp(keyCode: kVK_DownArrow) == [key("end", false)])
        // Back to a line end: the Ctrl we added is released first.
        #expect(t.keyDown(keyCode: kVK_RightArrow) == [key("ctrl_r", false), key("end", true)])
    }

    @Test func bothCommandKeysReleaseOnlyAtTheLast() {
        var t = KeyboardTranslator()
        _ = t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft)
        _ = t.flagsChanged(keyCode: kVK_RightCommand, flags: cmdLeft | cmdRight)
        _ = t.keyDown(keyCode: kVK_ANSI_A)
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: cmdRight) == [])
        #expect(t.flagsChanged(keyCode: kVK_RightCommand, flags: 0) == [key("a", false), key("ctrl_r", false)])
    }

    @Test func pcStyleCommandIsWindowsKey() {
        var t = KeyboardTranslator(style: .pc)
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: cmdLeft) == [key("meta_l", true)])
        #expect(t.keyDown(keyCode: kVK_ANSI_C) == [key("c", true)])
        #expect(t.flagsChanged(keyCode: kVK_Command, flags: 0) == [key("meta_l", false)])
    }

    @Test func optionIsAltAndRightOptionIsAltGr() {
        var t = KeyboardTranslator()
        #expect(t.flagsChanged(keyCode: kVK_Option, flags: 0x0020 | (1 << 19)) == [key("alt", true)])
        #expect(t.flagsChanged(keyCode: kVK_RightOption, flags: 0x0020 | 0x0040 | (1 << 19)) == [key("alt_r", true)])
    }

    @Test func reservedList() {
        let cmd: UInt = 1 << 20, ctrl: UInt = 1 << 18, opt: UInt = 1 << 19
        for k in [kVK_ANSI_Q, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Grave, kVK_ANSI_Comma, kVK_Tab, kVK_Space] {
            #expect(KeyboardTranslator.isReservedForMac(keyCode: k, flags: cmd))
        }
        #expect(KeyboardTranslator.isReservedForMac(keyCode: kVK_ANSI_F, flags: cmd | ctrl))
        #expect(!KeyboardTranslator.isReservedForMac(keyCode: kVK_ANSI_F, flags: cmd))
        #expect(KeyboardTranslator.isReservedForMac(keyCode: kVK_Escape, flags: cmd | opt))
        for k in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_R, kVK_ANSI_S] {
            #expect(!KeyboardTranslator.isReservedForMac(keyCode: k, flags: cmd))
        }
        #expect(!KeyboardTranslator.isReservedForMac(keyCode: kVK_ANSI_Q, flags: 0))
    }

    @Test func combosPressInOrderAndReleaseInReverse() {
        #expect(GuestKeyCombo.ctrlAltDelete.events == [
            key("ctrl", true), key("alt", true), key("delete", true),
            key("delete", false), key("alt", false), key("ctrl", false),
        ])
        for c in GuestKeyCombo.allCases {
            #expect(c.events.count == c.qcodes.count * 2)
            #expect(!c.title.isEmpty)
        }
    }
}

@Suite struct DisplayResizeTests {
    @Test func standardScalingIsOnePixelPerPoint() {
        let s = DisplayResize.guestSize(forContent: CGSize(width: 1283, height: 801), pixelsPerPoint: 1)
        #expect(s.width == 1280 && s.height == 800)
    }

    @Test func retinaScalingUsesScreenPixels() {
        let ppp = DisplayScaling.retina.pixelsPerPoint(backingScale: 2)
        #expect(ppp == 2)
        #expect(DisplayScaling.standard.pixelsPerPoint(backingScale: 2) == 1)
        let s = DisplayResize.guestSize(forContent: CGSize(width: 1440, height: 900), pixelsPerPoint: ppp)
        #expect(s.width == 2880 && s.height == 1800)
    }

    @Test func clampsToLimits() {
        let small = DisplayResize.guestSize(forContent: CGSize(width: 300, height: 200), pixelsPerPoint: 1)
        #expect(small.width == 800 && small.height == 600)
        let big = DisplayResize.guestSize(forContent: CGSize(width: 6000, height: 4000), pixelsPerPoint: 2)
        #expect(big.width == 7680 && big.height == 4320)
    }

    @Test func physicalSizeFollowsTheScreen() {
        // A 1512×982 pt screen that is 302×196 mm: half of it is ~151×98 mm.
        let mm = DisplayResize.physicalSize(forContent: CGSize(width: 756, height: 491),
                                            screenPoints: CGSize(width: 1512, height: 982),
                                            screenMillimetres: CGSize(width: 302, height: 196))
        #expect(mm.width == 151 && mm.height == 98)
        let none = DisplayResize.physicalSize(forContent: CGSize(width: 100, height: 100),
                                              screenPoints: CGSize(width: 1512, height: 982), screenMillimetres: .zero)
        #expect(none.width == 0 && none.height == 0)
    }

    @Test func tellsOurAnswerFromTheGuestsOwnChange() {
        #expect(DisplayResize.isAnswer(guestWidth: 1280, guestHeight: 800, to: (1280, 800)))
        #expect(DisplayResize.isAnswer(guestWidth: 1280, guestHeight: 798, to: (1280, 800)))
        #expect(!DisplayResize.isAnswer(guestWidth: 1024, guestHeight: 768, to: (1280, 800)))
        #expect(!DisplayResize.isAnswer(guestWidth: 1280, guestHeight: 800, to: nil))
    }
}

@Suite struct DisplayPreferencesTests {
    @Test func defaultsWhenMissingAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "seemless-dp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = VMFiles(directory: dir)
        #expect(DisplayPreferences.load(files) == DisplayPreferences())
        let p = DisplayPreferences(scaling: .retina, keyboard: .pc, resizeGuest: false)
        try p.save(files)
        #expect(DisplayPreferences.load(files) == p)
        // Unknown values decode to defaults instead of failing.
        try Data(#"{"scaling":"bogus","keyboard":"pc"}"#.utf8).write(to: DisplayPreferences.file(for: files))
        #expect(DisplayPreferences.load(files) == DisplayPreferences(scaling: .standard, keyboard: .pc, resizeGuest: true))
    }
}

@Suite struct FirstRunTests {
    func tempDrivers(withGraphics: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "seemless-drv-\(UUID().uuidString)")
        let gpu = root.appending(path: "viogpu3d")
        let net = root.appending(path: "netkvm")
        try FileManager.default.createDirectory(at: gpu, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: net, withIntermediateDirectories: true)
        try Data().write(to: net.appending(path: "netkvm.inf"))
        if withGraphics { try Data().write(to: gpu.appending(path: "viogpu3d.inf")) }
        return root
    }

    @Test func findsDriversFromTheEnvironment() throws {
        let root = try tempDrivers(withGraphics: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try #require(GuestDrivers.locate(environment: ["SEEMLESS_GUEST_DRIVERS": root.path],
                                                 executable: URL(filePath: "/nonexistent/x"),
                                                 currentDirectory: URL(filePath: "/nonexistent")))
        #expect(d.hasGraphicsDriver)
        #expect(d.driverNames == ["netkvm", "viogpu3d"])
    }

    @Test func folderWithoutTheGraphicsDriverDoesNotCount() throws {
        let root = try tempDrivers(withGraphics: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GuestDrivers.locate(environment: ["SEEMLESS_GUEST_DRIVERS": root.path]) == nil)
    }

    @Test func findsDriversInTheAppBundle() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "seemless-app-\(UUID().uuidString)/X.app")
        let gpu = app.appending(path: "Contents/Resources/guest-drivers/viogpu3d")
        try FileManager.default.createDirectory(at: gpu, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data().write(to: gpu.appending(path: "viogpu3d.inf"))
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let d = try #require(GuestDrivers.locate(environment: [:], executable: app.appending(path: "Contents/MacOS/X"),
                                                 currentDirectory: URL(filePath: "/nonexistent")))
        #expect(d.root.standardizedFileURL.path.hasSuffix("Contents/Resources/guest-drivers"))
    }

    func facts(arm: Bool = true, os: Int = 26, free: Int64? = 100_000_000_000, missing: [String] = [],
               drivers: GuestDrivers? = GuestDrivers(root: URL(filePath: "/x"))) -> FirstRun.HostFacts {
        FirstRun.HostFacts(isAppleSilicon: arm, macOSMajor: os, freeBytes: free, missingStackFiles: missing, drivers: drivers)
    }

    @Test func readyMac() {
        let r = FirstRun.requirements(facts())
        #expect(FirstRun.canInstall(facts()))
        #expect(r.filter { !$0.met }.map(\.id) == [.windowsISO])
    }

    @Test func blockingProblems() {
        #expect(!FirstRun.canInstall(facts(arm: false)))
        #expect(!FirstRun.canInstall(facts(os: 15)))
        #expect(!FirstRun.canInstall(facts(free: 10_000_000_000)))
        #expect(!FirstRun.canInstall(facts(missing: ["qemu-system-aarch64"])))
        var translated = facts(); translated.isTranslated = true
        #expect(!FirstRun.canInstall(translated))
    }

    @Test func missingDriverOnlyWarns() {
        let f = facts(drivers: nil)
        #expect(FirstRun.canInstall(f))
        let gpu = FirstRun.requirements(f).first { $0.id == .graphicsDriver }!
        #expect(!gpu.met && !gpu.blocking)
    }

    @Test func currentMacFactsAreReadable() {
        let f = FirstRun.HostFacts.current(storageRoot: FileManager.default.temporaryDirectory.appending(path: "nope/deeper"),
                                           stack: nil, assets: nil, drivers: nil)
        #expect(f.isAppleSilicon)
        #expect(f.macOSMajor >= 26)
        #expect(f.freeBytes != nil)
    }
}
