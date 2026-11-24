# Zen mode test list and results

The test list docs/05 asks for, with results. Each round records what ran,
on what, and what was **not** verified (no UI automation here: pointer,
clicks and keys need a person, see "Manual checks").

## How to run a round

No Windows agent exists yet (WP4.2), so the window list comes from
`seemlessctl mock-agent`. With `"windowManager"` in the script, the mock
answers `HitTest`, `SetWindowRect` and `WindowCommand` like Windows would
(`SimulatedWindowManager`). Pixels are the real guest's.

```bash
kit/.build/debug/seemlessctl vm run --root build/s3/root --name fw --export-display &
kit/.build/debug/seemlessctl mock-agent --socket /tmp/zt/agent.sock --script /tmp/zt/t1.json &
SEEMLESS_ROOT=$PWD/build/s3/root SEEMLESS_ZEN_AGENT=/tmp/zt/agent.sock \
  SEEMLESS_OPEN=zen:fw SEEMLESS_ZEN_STATS=1 build/app/Seemless.app/Contents/MacOS/Seemless
```

- **Seeing windows:** `CGWindowListCopyWindowInfo` (owner "Seemless") for
  frames and titles, and `screencapture -x -o -l <id>` for pixels. Compare
  with `seemlessctl screenshot`.
- **`SEEMLESS_ZEN_STATS=1`:** every 10 s the app logs hit tests,
  `SetWindowRect`s, frames and windows so far. It also logs the guest pixel
  of every mouse-down.
- **Echo check:** the mock logs every host request (`← setWindowRect`,
  `← windowCommand`). A guest-driven change must produce none.
- **Guest display size change on firmware:** `display size` is ignored by
  the UEFI shell. `exit` in the shell opens the setup UI at 640×480, and
  Continue goes back to 800×600: two real `SURFACES` generations.

## Round 1 — 2026-11-24, firmware VM `fw` + mock agent

Mac: built-in Retina display (1512×982 pt, Dock on the left). Guest scanout
800×600, 2D (firmware).

### 1. Window set

| Check | Result |
|-------|--------|
| Several windows, overlapping (B over A) | **Pass.** Mac z-order follows the snapshot (back to front) |
| Dialog with an owner | **Fixed.** It was a plain window, so clicking the owner covered it. Now a child window of its owner (docs/05). Moving the owner from the guest leaves the dialog where Windows has it |
| Transients (menu, tooltip) | **Pass.** Not mirrored |
| Partly off the display (right/bottom, left) | **Pass** for the crop: only the visible part shows. **Fixed:** dragging it on the Mac sent the clipped rectangle, so the guest window would shrink to what was visible. The model now keeps the full rectangle (`fullRect`); since round 2 moves are not sent at all, and a resize changes the full rectangle's size |
| Fully off the display | **Pass.** Not mirrored |
| Minimised when Zen starts | **Fixed.** It got no Mac window, so it could not be restored from the Dock. Now it is created minimised (in the Dock) |

### 2. Window life (simulated window manager, guest-driven)

| Check | Result |
|-------|--------|
| Guest move, minimise to Dock, restore, maximise, restore, `windowRemoved` | **Pass.** No host requests in the mock log (no echoes) |
| Owner moved by the guest, dialog stays | **Pass** (after the child-window fix) |
| Mac-side drag, edge resize, Cmd-W, Cmd-M, Dock restore | Manual: see "Manual checks" |

### 3. Agent problems

| Check | Result |
|-------|--------|
| Agent restart (`hello`) then a new snapshot | **Pass.** Removed window closed, kept window moved, new one added, same Mac window kept for the survivor |
| Agent silent (`pings: false`) | **Fixed.** The windows stayed up, frozen, forever. Now Zen ends after the 3 missed heartbeats (≈3 s) with an alert "The Windows agent stopped responding." (docs/05 "Agent lost"; there is no Desktop mode window yet to fall back to) |
| Agent disconnects | **Pass.** Windows close |
| Agent with no `HitTest` | Logic unchanged (UNSUPPORTED turns hit testing off). Clicks by hand: manual |
| VM stopped while in Zen | **Fixed, two bugs.** (a) Zen held `ctl.sock`, QEMU's only "other controller" monitor, so `seemlessctl vm stop` (and the app's `VMRemote`) got "Connection refused" for as long as Zen ran. Zen now has its own monitor, `input.sock` (docs/02). (b) After QEMU exited, the Zen windows stayed up frozen. Zen now ends when QMP closes, with no alert |
| Exit Zen and re-enter | **Fixed by reading:** the old session's end handler cleared the dictionary entry after a quick re-enter, leaking the new session's windows. It now checks identity. A second Enter while connecting is ignored. By hand: manual |
| Leaks / crashes | None seen: no crash reports; window lists empty after each end |

### 4. Guest display size changes

| Check | Result |
|-------|--------|
| 800×600 → 640×480 → 800×600 | **Fixed.** Geometry was fixed at start. Now the session polls the scanout size (250 ms) and re-clips every window. At 640×480 a window at x=650 disappeared and one at (−100, 400) was clipped to 150×80; both came back at 800×600. Crop at 640×480 matched the screenshot |
| Texture cache | **Fixed.** Textures of an old surface ring stayed cached (up to 9 surfaces). The cache is now keyed by the ring's generation |

### 5. Scale, Retina, edges

| Check | Result |
|-------|--------|
| `SEEMLESS_ZEN_SCALE=0.5` | **Pass.** A 300×200 guest window is 150×100 pt = 300×200 backing pixels, crisp |
| Scale 1 | **Pass.** Same size in points as guest pixels (upscaled 2×) |
| Window at guest y=0 | **Pass.** Its top is at the menu bar's bottom edge |
| Screen changes | **Changed:** the mapping now follows the primary screen's usable area (it used `NSScreen.main`, which follows the key window) and is redone when screens change. Side effect seen: when the Dock resizes, every window shifts by its change (1 pt) |

### 6. Performance

| Check | Before | After |
|-------|--------|-------|
| App CPU, idle, 0 / 1 / 10 Zen windows | 0.8% / 5.8% / 16.1% | 1.5% / 3.3% / 5.9% |
| Cause | A 120 Hz `CADisplayLink` per window, and one Metal command buffer per window per frame | One frame-driven loop per session (`DisplayClient.nextFrame`), skipping covered and minimised windows, and one command buffer for all windows per frame |

- **Frame rate:** the idle firmware screen still delivers **30 frames/s**
  (`ui/seemless` sends every refresh, changed or not). If the backend sent
  only changed frames, idle cost would be ≈0. Reported to the main session;
  the QEMU patch is not this round's to change.
- **Hover `HitTest` rate:** was one request per mouse-moved event with a
  reply (the owner's session measured ~1,500 a minute).
  - Now paced by `HoverHitTestThrottle`, which has tests: nothing within 3 px
    of the cached answer, one in flight, at most 10 a second while moving,
    and one trailing request where the pointer rests.
  - The cache is dropped when the window's rectangle changes or the agent
    restarts.
  - Rate by hand: manual.
- **`SetWindowRect` during a drag:** was debounced at 120 ms plus one at the
  end. Since round 2 a move sends nothing (Mac-only moves), and a live
  resize sends about 20 a second (`LiveResizePacer`, tested); the owner's
  resize of Notepad sent ~60.

### 7. Input

| Check | Result |
|-------|--------|
| Caps Lock | **Fixed by reading:** the Mac reports a lock state. Caps went down on "on" and up on "off", so the guest toggled once per two presses. Each change is now a full press |
| Left/right modifiers | **Fixed by reading:** releasing right Shift while left Shift was held sent another key-down. Now uses the device flags |
| Modifiers after focus loss | **Fixed by reading:** keys were released only when the view resigned first responder, which does not happen when another window or app becomes key. Now released on `windowDidResignKey` and app deactivation, through the same ordered queue as key-downs (a release could overtake a queued key-down before) |
| Trackpad scrolling | **Fixed by reading:** each precise scroll event was a full wheel click (dozens per gesture). Now accumulated (24 pt per click), mouse wheels by line, with horizontal scrolling (`wheel-left`/`wheel-right`) |
| Typing, click position, modifiers by hand | Manual |

### Manual checks

Done in round 2 on a real Windows VM instead (below).

## Round 2 — 2026-11-24, fresh Windows VM `zen1` + Notepad, with the owner

- **VM:** `zen1`, a Lean image built for this test (`image build --drivers
  build/s3/drivers`, `FIRSTBOOT_OK` in 7 min, snapshot `installed` before
  first start). It has the 3D driver (Metal scanout).
- **Licence:** the owner accepted Microsoft's licence page by clicking
  through a full-screen Zen window (a mock window covering the whole guest
  display). That was the first real click test: the click landed on Accept.
- **Network:** for the helper, the guest got a network driver. UTM's guest
  tools ISO was hot-plugged as a USB CD over QMP (`drive_add` + `device_add
  usb-storage`) and `NetKVM\w11\ARM64` installed with `pnputil`.
- **Windows:** at first the rectangle came from a mock script measured off a
  screenshot. Then it came from the stand-in helper
  (`proto/mock/zen-guest-helper.ps1` + `proto/mock/notepad-live.json`):
  Notepad's real frame, state and title.

| Check | Result |
|-------|--------|
| Crop is exactly Notepad | **Pass** (screenshot of the Zen window; rounded corners hide Windows' own) |
| Typing into Notepad | **Pass** (owner): the text appeared, and the helper reported the new title |
| Clicks land on the right pixel | **Pass**: the stats log's guest point for the owner's click was on the licence page's Accept button |
| Windows pointer | **Bug → fixed in the guest.** `viogpu3d` v0.6 draws a software cursor into the scanout (no CURSOR events), so it showed in the crop. Blank system cursors while Zen runs (helper; the agent in Z3); verified by pixels under the pointer position |
| Dragging the title bar | **Owner: wrong.** It moved Notepad inside Windows (no agent, so the click went to the guest), and the crop showed the old place. **Changed design:** moves are Mac-only, with the input offset; a standard-caption stand-in for `HitTest`. The owner then dragged it as intended |
| Resizing | **Owner: wrong**, it stretched. **Changed:** live resize, with the guest following at ~20 requests a second and the crop drawn 1:1. Owner: works |
| Resized taller than the guest's work area | **Owner: the taskbar showed.** The guest display was 1024×768. **Fixed:** the requested rectangle is kept in the work area (display minus a 48 px taskbar until the agent reports it), and the Mac window's maximum size is the work area. The guest display was set to 1504×944 (`display size`, accepted by Windows) |
| Another guest window on top of Notepad | Showed in the crop (twice: PowerShell consoles). Tier 2's known limit; the helper now keeps its windows on top and minimises its own console. The real fix is `PointerFocus` raising (Z3) and the atlas (Z4) |
| Zen start on a still screen | **Fixed:** it waited for a new frame (6-15 s on a still desktop). It now uses the display size QEMU announces on connect |
| Caps Lock, modifiers after focus loss | Not reported by the owner in this round |

## Round 3 — 2026-11-24, `fw` + mock agent: Zen → desktop on last window

The owner's requirement: when the last Windows app window closes, Zen ends and
the full desktop window opens. The mock script snapshots one window, then
minimises and restores it. It removes it and adds another 100 ms later (a
splash screen swap), then removes that one. The app's on-screen windows were
polled every 50 ms.

| Check | Result |
|-------|--------|
| Minimised only (in the Dock) | **Pass.** Zen stayed; the window came back on restore |
| Splash swap (remove, add 100 ms later) | **Pass.** Zen stayed; the new window opened |
| Last window removed | **Pass.** The Zen window closed, and 0.4 s later the desktop window `fw` (800×600 content) opened with the live screen (window screenshot seen). No alert. The mock agent saw the host disconnect, and QEMU had one `input.sock` client (the desktop window's) |
| Zen started with no windows; agent restart | Unit tests only (`ZenLastWindowWatchTests`) |

## Known gaps (not bugs in Z1)

- Windows windows that overlap the mirrored one in the guest show in its
  crop (tier 2). Needs `PointerFocus` raising (Z3) and the atlas (Z4).
- The work area is assumed (48 px taskbar at the bottom, 100%) until the
  agent reports it.

- Cmd is sent as the Windows key. Cmd-Tab away sends Win down, then Win up
  on focus loss, which can open Start. Fixed by the Cmd→Ctrl mapping (docs/07).
- No `SetHostInfo.work_area` is sent, so Windows' maximise does not match
  the Mac's usable area yet.
- The crop is tier 2: overlapping guest windows bleed into each other (Z4).
