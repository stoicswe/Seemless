import Carbon.HIToolbox
import Foundation

/// Keyboard and pointer input for the guest, sent with QMP `input-send-event`
/// (docs/05 "Input model"; S3 measured ~1 ms round trip). The event builders
/// are pure so they can be tested; `GuestInput` sends them.
public enum GuestInputEvent: Sendable, Equatable {
    case key(qcode: String, down: Bool)
    /// QEMU absolute axes, 0...32767 across the display.
    case absolute(x: Int, y: Int)
    case button(String, down: Bool)

    /// The QMP `InputEvent` objects for this event.
    public var qmp: [JSONValue] {
        switch self {
        case .key(let q, let down):
            return [.object(["type": "key", "data": .object([
                "down": .bool(down), "key": .object(["type": "qcode", "data": .string(q)])])])]
        case .absolute(let x, let y):
            return [
                .object(["type": "abs", "data": .object(["axis": "x", "value": .number(Double(x))])]),
                .object(["type": "abs", "data": .object(["axis": "y", "value": .number(Double(y))])]),
            ]
        case .button(let b, let down):
            return [.object(["type": "btn", "data": .object(["down": .bool(down), "button": .string(b)])])]
        }
    }

    /// QEMU button names for the Mac's mouse buttons (0 left, 1 right, 2 middle).
    public static func buttonName(_ number: Int) -> String? {
        switch number {
        case 0: "left"
        case 1: "right"
        case 2: "middle"
        case 3: "side"
        case 4: "extra"
        default: nil
        }
    }

    /// Scroll as wheel clicks: QEMU has no smooth scrolling for the tablet.
    /// Positive `deltaY` scrolls up, positive `deltaX` scrolls left (AppKit's signs).
    public static func wheel(deltaY: Double) -> [GuestInputEvent] { wheel(clicksY: deltaY > 0 ? 1 : deltaY < 0 ? -1 : 0) }

    public static func wheel(clicksY: Int = 0, clicksX: Int = 0) -> [GuestInputEvent] {
        func clicks(_ n: Int, _ positive: String, _ negative: String) -> [GuestInputEvent] {
            let b = n > 0 ? positive : negative
            return Array(repeating: [GuestInputEvent.button(b, down: true), .button(b, down: false)],
                         count: min(abs(n), ScrollAccumulator.maxClicksPerEvent)).flatMap { $0 }
        }
        return clicks(clicksY, "wheel-up", "wheel-down") + clicks(clicksX, "wheel-left", "wheel-right")
    }
}

/// Turns Mac scroll events into whole wheel clicks.
///
/// A mouse wheel reports lines: one line is one click. A trackpad or Magic
/// Mouse reports precise point deltas, dozens of events per gesture, plus
/// momentum: sending a click for each would scroll the guest far too fast,
/// so points are accumulated and one click is sent per `pointsPerClick`.
public struct ScrollAccumulator: Sendable {
    /// Points of precise scrolling per wheel click (Windows scrolls 3 lines per click).
    public static let pointsPerClick = 24.0
    /// Cap per event, so a burst from a hostile or broken device stays small.
    public static let maxClicksPerEvent = 10

    private var restX = 0.0, restY = 0.0

    public init() {}

    /// Wheel clicks (x, y) for one scroll event; positive y is up, positive x is left.
    public mutating func clicks(deltaX: Double, deltaY: Double, precise: Bool) -> (x: Int, y: Int) {
        guard precise else {
            func lines(_ d: Double) -> Int { d == 0 ? 0 : d > 0 ? max(1, Int(d.rounded())) : min(-1, Int(d.rounded())) }
            return (lines(deltaX), lines(deltaY))
        }
        restX += deltaX; restY += deltaY
        let x = Int(restX / Self.pointsPerClick), y = Int(restY / Self.pointsPerClick)
        restX -= Double(x) * Self.pointsPerClick
        restY -= Double(y) * Self.pointsPerClick
        return (x, y)
    }

    /// A new gesture starts from zero (leftover points do not carry over).
    public mutating func reset() { restX = 0; restY = 0 }
}

/// macOS virtual key codes (Carbon `kVK_*`, layout-independent positions)
/// to QEMU qcodes, which are PC scan-code positions. Cmd maps to the Windows
/// key; the Cmd→Ctrl shortcut option is docs/07's and comes later.
public enum GuestKeyMap {
    public static let qcodes: [Int: String] = {
        var m: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
            kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
            kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
            kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
            kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Return: "ret", kVK_Escape: "esc", kVK_Space: "spc", kVK_Tab: "tab",
            kVK_Delete: "backspace", kVK_ForwardDelete: "delete",
            kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up", kVK_DownArrow: "down",
            kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pgup", kVK_PageDown: "pgdn",
            kVK_Shift: "shift", kVK_RightShift: "shift_r", kVK_Control: "ctrl", kVK_RightControl: "ctrl_r",
            kVK_Option: "alt", kVK_RightOption: "alt_r", kVK_Command: "meta_l", kVK_RightCommand: "meta_r",
            kVK_CapsLock: "caps_lock",
            kVK_ANSI_Minus: "minus", kVK_ANSI_Equal: "equal", kVK_ANSI_LeftBracket: "bracket_left",
            kVK_ANSI_RightBracket: "bracket_right", kVK_ANSI_Semicolon: "semicolon",
            kVK_ANSI_Quote: "apostrophe", kVK_ANSI_Comma: "comma", kVK_ANSI_Period: "dot",
            kVK_ANSI_Slash: "slash", kVK_ANSI_Backslash: "backslash", kVK_ANSI_Grave: "grave_accent",
            kVK_ISO_Section: "less",
            kVK_ANSI_Keypad0: "kp_0", kVK_ANSI_Keypad1: "kp_1", kVK_ANSI_Keypad2: "kp_2",
            kVK_ANSI_Keypad3: "kp_3", kVK_ANSI_Keypad4: "kp_4", kVK_ANSI_Keypad5: "kp_5",
            kVK_ANSI_Keypad6: "kp_6", kVK_ANSI_Keypad7: "kp_7", kVK_ANSI_Keypad8: "kp_8",
            kVK_ANSI_Keypad9: "kp_9", kVK_ANSI_KeypadDecimal: "kp_decimal",
            kVK_ANSI_KeypadMultiply: "kp_multiply", kVK_ANSI_KeypadPlus: "kp_add",
            kVK_ANSI_KeypadMinus: "kp_subtract", kVK_ANSI_KeypadDivide: "kp_divide",
            kVK_ANSI_KeypadEnter: "kp_enter", kVK_ANSI_KeypadEquals: "kp_equals",
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12]
        for (i, k) in f.enumerated() { m[k] = "f\(i + 1)" }
        return m
    }()

    public static func qcode(forKeyCode code: Int) -> String? { qcodes[code] }

    /// Modifier keys arrive as `flagsChanged`; this tells which flag a
    /// modifier qcode corresponds to, so the host can send down or up.
    public static func isModifier(_ qcode: String) -> Bool {
        ["shift", "shift_r", "ctrl", "ctrl_r", "alt", "alt_r", "meta_l", "meta_r", "caps_lock"].contains(qcode)
    }

    /// `NSEvent.modifierFlags` bits that tell the left and right modifier
    /// keys apart (IOKit's `NX_DEVICE*KEYMASK`), and Caps Lock's flag.
    static let deviceFlag: [String: UInt] = [
        "ctrl": 0x0001, "shift": 0x0002, "shift_r": 0x0004, "meta_l": 0x0008, "meta_r": 0x0010,
        "alt": 0x0020, "alt_r": 0x0040, "ctrl_r": 0x2000, "caps_lock": 1 << 16,
    ]

    /// Guest key events for one `flagsChanged` event (`keyCode` and the raw
    /// `modifierFlags`): the modifier key went down when its own device flag
    /// is now set, up when it is clear. Left and right keys are separate, so
    /// releasing one while the other is held is still a release.
    ///
    /// Caps Lock is different: the Mac reports a lock state, toggled once per
    /// press, while a PC toggles caps lock on every key-down. Each change is
    /// therefore a full press (down then up), so both sides toggle together
    /// and the key is never left held in the guest.
    public static func modifierEvents(keyCode: Int, flags: UInt) -> [GuestInputEvent] {
        guard let q = qcode(forKeyCode: keyCode), let mask = deviceFlag[q] else { return [] }
        if q == "caps_lock" { return [.key(qcode: q, down: true), .key(qcode: q, down: false)] }
        return [.key(qcode: q, down: flags & mask != 0)]
    }
}

/// Sends input over a QMP connection (the VM's control socket).
public actor GuestInput {
    private let qmp: QMPClient
    /// Keys currently held, released on `releaseAll` (focus loss: docs/05
    /// "Mac → Windows focus loss" — no stuck modifiers in the guest).
    private var held: Set<String> = []

    public init(qmp: QMPClient) { self.qmp = qmp }

    public func send(_ events: [GuestInputEvent]) async {
        guard !events.isEmpty else { return }
        for e in events {
            if case .key(let q, let down) = e { if down { held.insert(q) } else { held.remove(q) } }
        }
        _ = try? await qmp.execute("input-send-event", arguments: ["events": .array(events.flatMap(\.qmp))])
    }

    public func releaseAll() async {
        let keys = held
        held = []
        await send(keys.sorted().map { .key(qcode: $0, down: false) })
    }
}
