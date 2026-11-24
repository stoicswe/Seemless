import Carbon.HIToolbox
import Foundation

/// How the Mac's Command key reaches Windows (docs/07 "Keyboard").
public enum KeyboardStyle: String, Codable, Sendable, CaseIterable {
    /// Default. Cmd-C/V/X/Z/A/S/F/T/W/N/P/O and the other Cmd shortcuts
    /// become Ctrl shortcuts, so Mac muscle memory works. Cmd-Left/Right go
    /// to the start/end of the line (Home/End), Cmd-Up/Down to the start/end
    /// of the document (Ctrl-Home/End). Cmd pressed and released alone is
    /// the Windows key (opens Start).
    case mac
    /// Cmd is the Windows key; nothing is remapped.
    case pc

    public var title: String {
        switch self {
        case .mac: "Mac style (⌘ shortcuts act as Ctrl)"
        case .pc: "PC style (⌘ is the Windows key)"
        }
    }
}

/// Turns Mac key events (virtual key codes and `NSEvent.modifierFlags`
/// raw values) into guest key events for one desktop window. Pure and
/// stateful: one per window, fed in event order. Option is Alt, Right
/// Option is AltGr, Control is Ctrl in both styles.
public struct KeyboardTranslator: Sendable {
    public var style: KeyboardStyle

    /// Command keys currently down (left and right are separate).
    private var commandKeys: Set<Int> = []
    /// A key was pressed while Command was down (so releasing Command is
    /// not a lone Windows-key tap).
    private var commandUsed = false
    /// Mac style: the Ctrl we press in the guest on behalf of Command.
    /// Right Ctrl, so it never collides with the real (left) Control key.
    private var commandCtrl = false
    /// Keys pressed while Command was down, with what we sent for them:
    /// AppKit does not deliver their key-up while Command is held, so they
    /// are released at the latest when Command goes up.
    private var commandKeysSent: [Int: [String]] = [:]

    static let commandCtrlQcode = "ctrl_r"

    public init(style: KeyboardStyle = .mac) { self.style = style }

    // NSEvent.ModifierFlags raw bits (device-independent).
    static let shiftFlag: UInt = 1 << 17
    static let controlFlag: UInt = 1 << 18
    static let optionFlag: UInt = 1 << 19
    static let commandFlag: UInt = 1 << 20

    /// Shortcuts that stay with macOS and the app (docs/07 "Reserved for
    /// macOS"): Cmd-Q, Cmd-H, Cmd-Option-H, Cmd-M, Cmd-`, Cmd-, (Settings),
    /// Ctrl-Cmd-F (full screen), Cmd-Option-Esc (Force Quit). Cmd-Tab and
    /// Cmd-Space never reach an app. Everything else goes to the guest.
    public static func isReservedForMac(keyCode: Int, flags: UInt) -> Bool {
        guard flags & commandFlag != 0 else { return false }
        switch keyCode {
        case kVK_ANSI_Q, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Grave, kVK_ANSI_Comma, kVK_Tab, kVK_Space:
            return true
        case kVK_ANSI_F:
            return flags & controlFlag != 0
        case kVK_Escape:
            return flags & optionFlag != 0
        default:
            return false
        }
    }

    /// A reserved shortcut went to macOS: Command was used, so releasing it
    /// must not tap the Windows key.
    public mutating func noteReservedShortcut() {
        if !commandKeys.isEmpty { commandUsed = true }
    }

    /// One `flagsChanged` event.
    public mutating func flagsChanged(keyCode: Int, flags: UInt) -> [GuestInputEvent] {
        guard style == .mac, keyCode == kVK_Command || keyCode == kVK_RightCommand else {
            return GuestKeyMap.modifierEvents(keyCode: keyCode, flags: flags)
        }
        guard let q = GuestKeyMap.qcode(forKeyCode: keyCode), let mask = GuestKeyMap.deviceFlag[q] else { return [] }
        if flags & mask != 0 {
            if commandKeys.isEmpty { commandUsed = false }
            commandKeys.insert(keyCode)
            return []
        }
        guard commandKeys.remove(keyCode) != nil, commandKeys.isEmpty else { return [] }
        var events = releaseCommandKeys()
        if commandCtrl {
            events.append(.key(qcode: Self.commandCtrlQcode, down: false))
            commandCtrl = false
        } else if !commandUsed {
            events += [.key(qcode: "meta_l", down: true), .key(qcode: "meta_l", down: false)]
        }
        return events
    }

    /// One `keyDown` (repeats should be dropped by the caller: Windows
    /// repeats held keys itself).
    public mutating func keyDown(keyCode: Int) -> [GuestInputEvent] {
        guard let q = GuestKeyMap.qcode(forKeyCode: keyCode) else { return [] }
        guard style == .mac, !commandKeys.isEmpty else { return [.key(qcode: q, down: true)] }
        commandUsed = true
        var events: [GuestInputEvent] = []
        // Pressed again with Command still down: its key-up never came.
        if let sent = commandKeysSent.removeValue(forKey: keyCode) {
            events += sent.reversed().map { .key(qcode: $0, down: false) }
        }
        let keys: [String]
        switch keyCode {
        case kVK_LeftArrow, kVK_RightArrow:
            // Home/End without Ctrl (Ctrl-Home is the document start).
            if commandCtrl {
                events.append(.key(qcode: Self.commandCtrlQcode, down: false))
                commandCtrl = false
            }
            keys = [keyCode == kVK_LeftArrow ? "home" : "end"]
        case kVK_UpArrow, kVK_DownArrow:
            events += ensureCommandCtrl()
            keys = [keyCode == kVK_UpArrow ? "home" : "end"]
        default:
            events += ensureCommandCtrl()
            keys = [q]
        }
        commandKeysSent[keyCode] = keys
        events += keys.map { .key(qcode: $0, down: true) }
        return events
    }

    public mutating func keyUp(keyCode: Int) -> [GuestInputEvent] {
        if let sent = commandKeysSent.removeValue(forKey: keyCode) {
            return sent.reversed().map { .key(qcode: $0, down: false) }
        }
        guard let q = GuestKeyMap.qcode(forKeyCode: keyCode) else { return [] }
        return [.key(qcode: q, down: false)]
    }

    /// Forget held state after focus loss (the guest side is released by
    /// `GuestInput.releaseAll`).
    public mutating func reset() {
        commandKeys = []
        commandUsed = false
        commandCtrl = false
        commandKeysSent = [:]
    }

    private mutating func ensureCommandCtrl() -> [GuestInputEvent] {
        guard !commandCtrl else { return [] }
        commandCtrl = true
        return [.key(qcode: Self.commandCtrlQcode, down: true)]
    }

    private mutating func releaseCommandKeys() -> [GuestInputEvent] {
        let events = commandKeysSent.keys.sorted().flatMap { k in
            commandKeysSent[k]!.reversed().map { GuestInputEvent.key(qcode: $0, down: false) }
        }
        commandKeysSent = [:]
        return events
    }
}

/// Key combinations a Mac keyboard cannot type into Windows directly (or
/// that macOS keeps), sent from the window's Keyboard menu.
public enum GuestKeyCombo: String, CaseIterable, Sendable {
    case ctrlAltDelete, ctrlShiftEscape, altTab, altF4, windows, windowsL, printScreen

    public var title: String {
        switch self {
        case .ctrlAltDelete: "Ctrl-Alt-Delete"
        case .ctrlShiftEscape: "Ctrl-Shift-Esc (Task Manager)"
        case .altTab: "Alt-Tab"
        case .altF4: "Alt-F4 (Close Window)"
        case .windows: "Windows Key (Start)"
        case .windowsL: "Windows-L (Lock)"
        case .printScreen: "Print Screen"
        }
    }

    public var qcodes: [String] {
        switch self {
        case .ctrlAltDelete: ["ctrl", "alt", "delete"]
        case .ctrlShiftEscape: ["ctrl", "shift", "esc"]
        case .altTab: ["alt", "tab"]
        case .altF4: ["alt", "f4"]
        case .windows: ["meta_l"]
        case .windowsL: ["meta_l", "l"]
        case .printScreen: ["print"]
        }
    }

    /// Keys down in order, then up in reverse order.
    public var events: [GuestInputEvent] {
        qcodes.map { .key(qcode: $0, down: true) } + qcodes.reversed().map { .key(qcode: $0, down: false) }
    }
}
