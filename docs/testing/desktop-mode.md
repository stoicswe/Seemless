# Desktop mode and first run (Preview 1 P2)

Acceptance for WP3.4 (fresh user → working desktop mode without Terminal)
and WP3.2 (type in Notepad; resize changes the guest resolution), plus
WP3.5's audio and scaling. Screenshots are in `build/p2/shots/` (not
committed: Microsoft wallpaper and licence text).

## Round 1: 2026-11-24, VM "Windows 11" under `build/p2/root`

**How it was driven:** nobody clicked the app's buttons. The flow ran
through developer switches that set the same state the buttons set:
`SEEMLESS_FIRSTRUN_ISO`, `_PROFILE=lean`, `_GO=1`. Keys went through the
desktop window as synthetic `NSEvent`s (`SEEMLESS_DISPLAY_TYPE`, now with
`{cmd}`, `{cmd+a}`, `{shift+h}` chords), with resize, full screen and Send
Keys run by their switches. **The owner accepted Microsoft's licence by
clicking Accept in the desktop window**: the first real-pointer use of the
window. Results were checked with `seemlessctl screenshot` and window
captures.

| Check | Result |
|-------|--------|
| Welcome on an empty library | Shown; requirements all met on this Mac (Apple silicon, macOS 27.3, 799 GB free, components, drivers `netkvm, viogpu3d, vioser`) (`welcome1.png`) |
| Install from the ISO (`Windows11_Client_arm64_en-us_26300_9457.iso`, Lean) | Stages advanced in the app (`install1.png`); `FIRSTBOOT_OK`, `licenseAcceptedOnHost: false`, about 10 min; no QEMU window (exported display); viogpu3d already drove the screen during first boot (`source=metal`) |
| Start after install | Automatic; desktop window opened with the licence bar (`firststart.png`); the app shows "Next: accept the licence in Windows" (`install2.png`) |
| Licence | Windows showed "Please review the License Agreement" (`oobe.png`); **accepted by the owner** in the window, then auto-logon to the desktop (`desk.png`) |
| Typing in Notepad | Lone ⌘ tap → Start, `notepad` ↵, `hello from seemless 123`, Shift-h `ello` Shift-w `orld`, ⌘A → Ctrl-A selected all: "36 of 36 characters" (`notepad.png`) |
| Resize → guest resolution | Window content 1280×720 pt → `requested 1280x720 (255x143 mm)`, guest 1280×720 within a second, window filled with no bars (`resize.png`, `resize-win.png`). Opening the window restored a saved frame and asked for 1024×804 by itself, also applied |
| Full screen + Retina scaling | Guest 3024×1898 (native pixels) (`fs.png`). Windows stayed at 100 % scale (tiny UI): Retina needs 200 % set in Windows until the agent sets DPI |
| Send Keys ▸ Ctrl-Alt-Delete | Windows security screen (`cad.png`); Alt-F4 closed Task Manager |
| Audio device | Sound panel: "Speakers, 2- Audio Device, Default Device" (`sound.png`) |
| Audible audio | **Pass**: the owner heard the Windows speaker test on the Mac ("audio is good") |

**Found:** typing into the Ctrl-Alt-Delete screen right after Escape
selected Task Manager (keys arrived before the screen closed). Test-script
timing only; nothing in the product.

**Not verified by a person:** dragging the window edge (`windowDidEndLiveResize`
path; the switch calls the same request), the green button / Ctrl-Cmd-F,
the Display menu's own items (the switches call the same methods), real
keyboard shortcuts, the PC keyboard style, and clicking through the
welcome flow.
