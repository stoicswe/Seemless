import Carbon.HIToolbox

/// macOS virtual key code → QEMU qcode (enough for the spike; the product
/// keymap belongs in SeemlessKit with tests).
let qcodeForKeyCode: [Int: String] = {
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
        kVK_ANSI_Minus: "minus", kVK_ANSI_Equal: "equal", kVK_ANSI_LeftBracket: "bracket_left",
        kVK_ANSI_RightBracket: "bracket_right", kVK_ANSI_Semicolon: "semicolon",
        kVK_ANSI_Quote: "apostrophe", kVK_ANSI_Comma: "comma", kVK_ANSI_Period: "dot",
        kVK_ANSI_Slash: "slash", kVK_ANSI_Backslash: "backslash", kVK_ANSI_Grave: "grave_accent",
    ]
    let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    for (i, k) in f.enumerated() { m[k] = "f\(i + 1)" }
    return m
}()
