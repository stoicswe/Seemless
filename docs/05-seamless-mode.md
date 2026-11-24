# 05 — Zen mode (seamless)

**Zen mode** is the product name (owner, 2026-11-24) for what this document
and older ones call seamless mode.

- Each Windows top-level window is mirrored by one borderless `NSWindow`.
- The Windows desktop, taskbar and wallpaper are never shown.
- There is no Mac title bar and there are no traffic-light buttons: the
  Windows app's own frame, title bar and buttons are the window, so it looks
  and behaves like a native Windows app sitting on the Mac.
- Code may keep "seamless" in identifiers (`WindowBridge`, `docs/testing/seamless.md`).

## The Zen window

What "chrome-less, as if native" means on the Mac side. It holds for every
pixel tier below.

| Concern | Decision |
|---------|----------|
| Window type | `NSWindow` subclass, `styleMask = [.borderless, .resizable, .miniaturizable]`: still no title bar and no traffic lights, but macOS's own edge resizing and Dock minimise apply. It overrides `canBecomeKey`/`canBecomeMain` to return true, because a borderless window cannot be key by default. Set `isOpaque = false`, a clear background and `collectionBehavior = .managed`, so it takes part in Mission Control, Spaces and Stage Manager |
| Window buttons | None on the Mac side. Minimise, maximise and close are the Windows app's own title-bar buttons, clicked in the guest (hit-test `HTMINBUTTON`/`HTMAXBUTTON`/`HTCLOSE` goes through). The agent reports the result and the host mirrors it: a Windows minimise becomes a **Dock minimise**; restoring from the Dock sends `WindowCommand restore`; maximise follows the guest's rectangle; `WindowRemoved` closes the Mac window. Mac shortcuts go the other way through `WindowCommand`: Cmd-W sends close (`WM_CLOSE`, so "save changes?" prompts still appear; the Mac window closes only when the guest window is gone), Cmd-M minimises. A Mac-side state change becomes a command only when it differs from the guest's last reported state, so guest changes are never echoed back |
| Corners and shadow | **macOS-style rounded corners** (owner, 2026-11-24): 16 pt, continuous curve, clipped by a plain container view (a Metal layer that is the window's top view is not clipped by its own radius). That is larger than Windows 11's 8 px, so the guest's own corners never show. DWM's shadow lies outside `DWMWA_EXTENDED_FRAME_BOUNDS` and is never captured; the Mac draws the shadow (`hasShadow = true`), and it follows the rounded shape |
| Active state | A Windows title bar draws itself active or inactive. Key-window changes must reach the guest (`Activate`/`Deactivate`, input model below), or a window looks focused while it isn't |
| Moving | **Mac-only** (owner, 2026-11-24: "feel like a native Mac app, but be the native app in the Windows VM"). A single-click mouse-down on the caption starts `NSWindow.performDrag(with:)`: a native move with no lag, plus Mac edge snapping and Stage Manager. **The guest window does not move**: each Zen window keeps an offset between its guest position and its Mac position, and pointer input is mapped through it (`ZenGeometry.macFrame(for:offset:)`, `guestPoint(fromMac:offset:)`). Nothing is sent to the guest for a move. An owned dialog opens at its owner's offset and moves with it (child window). "Caption" comes from the agent's `HitTest`, asked while the pointer hovers (cached, paced by `HoverHitTestThrottle`: ≤10/s while moving, one where the pointer rests). An agent that cannot hit-test gets a stand-in: the caption strip of a standard Windows 11 frame (`ZenHitArea.standardFrame`, 32 px minus the three buttons). Double-clicks on the caption go to Windows (maximise or restore) |
| Resizing | **Live, re-laid out, never stretched** (owner, 2026-11-24). Native macOS edge resize; during the drag `SetWindowRect` sends the new size about 20 times a second (`LiveResizePacer`), so the app lays itself out as the edge moves. The crop is drawn 1:1 from the top-left (`ZenGeometry.fit`); where the guest has not caught up yet the view shows a neutral background. The requested guest rectangle is kept wholly inside the guest's work area (`ZenGeometry.place`; the guest window may move to fit, since only the Mac position is the user's): outside it, the taskbar and other guest windows show in the crop (seen in testing). The Mac window's `maxSize` is the work area. When the resize ends the Mac frame snaps to the size the app really took |
| Maximise / snap | The guest's work area equals the Mac screen's `visibleFrame` (`SetHostInfo.work_area`), so Windows' own maximise fills exactly the area a Mac zoom would. Windows Snap Layouts (hover on maximise) are guest UI, and shown as a transient |
| Menu bar | With a Zen window key, the Mac menu bar shows Seemless's menus in v1. Windows apps keep their in-window menus. In v2 (M6 stub apps), a per-app host process gives each Windows app its own name, icon, Dock tile and Cmd-Tab entry, which completes the "native app" illusion |
| DPI | One guest pixel maps to one Mac backing pixel. The guest runs at the Mac's scale (200% on Retina), so Windows apps appear at their natural size |
| Pointer | **The Windows pointer is never shown** (owner, 2026-11-24). Only the Mac pointer is visible over Zen windows, so nothing gives away a second system. Its shape still follows the guest (I-beam over text, resize arrows on window edges, hand over links), as the matching native `NSCursor`, never Windows' bitmap. **UTM's `viogpu3d` v0.6 draws a software cursor into the scanout** (no `CURSOR`/`MOUSE` events; S3, and seen in every Zen crop on `zen1`), so the host cannot leave it out. While Zen is active the guest side replaces Windows' standard system cursors with blank ones (`SetSystemCursor`) and restores them on exit (`SPI_SETCURSORS`): the agent's job in Z3; `proto/mock/zen-guest-helper.ps1` does it for testing. A driver with a hardware cursor would make this unnecessary. Mapping a bitmap to a native shape is unreliable, so the agent reports the cursor's kind (standard `IDC_*` handles compared via `GetCursorInfo`); a custom cursor falls back to the arrow. This is a small protocol addition (`CursorShape { kind }`, G→H) for Z3 |
| Clipboard | **Copy and paste work both ways** (owner, 2026-11-24): text, RTF, HTML and images, as designed in docs/06 ("Clipboard and drag and drop", WP4.5). It is lazy: formats are announced on change and data is fetched on paste. Data only crosses while a Zen window or a Mac app is key, so background apps can't read the other side's clipboard. It is in the protocol schema already (`ClipboardOffer`/`ClipboardRequest` + bulk) and needs the Windows agent. It is Zen step Z3b below |
| Escape hatch | A Seemless menu-bar item and a shortcut toggle Zen ↔ Desktop. "Agent lost" falls back to Desktop automatically (mode transitions below) |

## The core problem: occlusion

A VM display is one composited image. If guest window A overlaps guest window
B, B's hidden pixels do not exist in that image. Cropping rectangles out of
the desktop (the VirtualBox approach) therefore breaks as soon as a Mac window
sits between two Windows windows, or two Windows windows overlap.

Parallels solves this with a proprietary driver that exports per-window
surfaces. We get the same result with stock Windows APIs, because with Triton
the guest has a real GPU and DWM keeps every window's content in its own GPU
surface.

## Design: capture to an atlas

```
Guest                                                   Host
─────                                                   ────
DWM redirection surface for HWND 1 ─┐
DWM redirection surface for HWND 2 ─┼─ WGC capture ─► agent D3D11 device
DWM redirection surface for HWND n ─┘        │
                                             ▼ CopySubresourceRegion per dirty window
                         Atlas swapchain, fullscreen on display 2 (scanout 1)
                                             │                         │
                                             └── virtio-gpu scanout ──►│ IOSurface "atlas"
agent ── WindowUpdate{hwnd, rect, atlasRect, serial} ─ virtio-serial ─►│ WindowBridge
                                                                       ▼
                                                       NSWindow per HWND samples its atlasRect
```

1. The VM has two virtio-gpu outputs. Display 1 is the normal Windows desktop
   (never shown in seamless mode). Display 2 is the **atlas**, e.g.
   8192×8192, set as a non-primary monitor positioned far from display 1.
2. The agent creates one `GraphicsCaptureItem` per tracked window
   (`CreateForWindow`), with `IsCursorCaptureEnabled = false` and
   `IsBorderRequired = false`, and a free-threaded frame pool on its own
   D3D11 device (on the Triton adapter).
3. A shelf/skyline allocator assigns each window a rectangle in the atlas,
   padded by 2 px. Allocations are stable across frames; a resize reallocates.
4. On each `FrameArrived`, the agent copies the frame into its atlas rect and
   marks it dirty. Once per vblank it presents the atlas swapchain and sends
   one `AtlasFrame` message listing the windows updated in that present, with
   the present serial.
5. The host receives the atlas scanout damage (via the display backend) and
   the `AtlasFrame` message, matches them by serial, and each `NSWindow`'s
   layer redraws from its sub-rectangle.

Why this design:

- No changes to the GPU driver or QEMU beyond a second scanout.
- Occluded, off-screen (but not minimised) windows keep updating.
- Per-pixel alpha comes through, so Windows 11 rounded corners and
  non-rectangular windows work without shape masks.
- Cost: one GPU copy per changed window per frame in the guest, plus one
  frame of latency. Acceptable for apps; games use game mode instead.

Risks to prove in spike S5: WGC works on the Triton driver; a second scanout
works end to end; `IsBorderRequired = false` is honoured without a consent
prompt for a LocalSystem-spawned, session-interactive process; throughput with
~20 windows at 4K total area.

### Fallback tiers

The bridge must support three pixel sources behind one interface, chosen per
window:

| Tier | Source | Used when |
|------|--------|-----------|
| 1 | Atlas (WGC) | Default |
| 2 | Crop of scanout 0 | WGC fails for a window (some protected/DRM windows capture black; some legacy layered windows), or before the 3D driver is up. Requires the window to be unobscured in the guest, which the "window under cursor is topmost" rule below mostly ensures |
| 3 | Direct scanout 0 | Game mode: a fullscreen/borderless-fullscreen window on display 1 |

Build tier 2 first (M5a): it needs only window rectangles and exercises the
whole bridge. Tier 1 lands in M5b.

## Which windows are mirrored

The agent enumerates top-level windows (`EnumWindows` at start, then
`SetWinEventHook` for `EVENT_OBJECT_CREATE/DESTROY/SHOW/HIDE/LOCATIONCHANGE/
NAMECHANGE/CLOAKED/UNCLOAKED`, `EVENT_SYSTEM_FOREGROUND/MINIMIZESTART/
MINIMIZEEND/MOVESIZESTART/MOVESIZEEND`) and classifies each:

| Class | Rule (sketch) | Host representation |
|-------|---------------|---------------------|
| **App window** | Visible, not cloaked (`DWMWA_CLOAKED`), not a tool window, has no owner or has `WS_EX_APPWINDOW`, non-empty rect | Normal `NSWindow`, appears in Mission Control, belongs to a Dock app |
| **Owned dialog** | Visible, has an owner that is mirrored | `NSWindow` added as child window of the owner's window (stays above it) |
| **Transient** | Menus (`#32768`), tooltips, combo dropdowns, IME candidates, drag images, `WS_EX_NOACTIVATE` popups | Non-activating borderless `NSPanel` at pop-up menu level, no shadow override, never key |
| **Shell** | `Shell_TrayWnd`, `Progman`, `WorkerW`, Start/Search hosts, notification toasts, our own agent windows | Not mirrored. Start menu and tray get dedicated host UI (07) |
| **Fullscreen** | Covers display 1 exactly, or exclusive fullscreen | Triggers game mode |

Use `DWMWA_EXTENDED_FRAME_BOUNDS` for the visible rectangle (GetWindowRect
includes invisible resize borders). Classification rules will need per-app
exceptions; keep them in a data file (`guest/agent/rules.toml`) with tests
built from recorded window dumps, not scattered `if`s.

## Geometry model

- Guest display 1 is a single virtual monitor whose pixel grid maps 1:1 onto
  the union of Mac displays (in backing pixels). A window at guest pixel
  (x, y) is shown at the corresponding Mac point. Keeping positions in sync
  matters because apps position menus, tooltips and child dialogs relative to
  their own windows and to screen edges.
- **Mac position is independent (owner, 2026-11-24).** A Zen window first
  appears at the mapped point, but the user's moves change only the Mac
  window: each Zen window has an offset from the mapping, and input goes
  through it. Menus, tooltips and owned dialogs that an app places relative
  to its window are shown at their owner's offset (dialogs today, transients
  in Z5), so they still land next to it. The guest is free to place its
  windows wherever suits the crop: the host keeps a resized window inside
  the guest's work area.
- The mapping follows the primary screen's usable area (`NSScreen.screens.first`,
  not `NSScreen.main`, which follows the key window) and is redone when
  screens change.
- The usable work area (excluding Mac menu bar and Dock) is pushed to the
  guest with `SPI_SETWORKAREA` so maximise fills the right region.
- **Guest z-order is invisible** to the user in tier 1, so the agent is free
  to reorder guest windows for input purposes (below). Mac z-order is the only
  one the user sees.

### Move and resize

| Phase | Behaviour |
|-------|-----------|
| Move | **Mac-only** (2026-11-24, replaces v1 guest-driven and v2 host-driven-with-`SetWindowPos`): the `NSWindow` moves natively; the guest window stays put; input is mapped through the window's offset ("The Zen window", Moving) |
| Resize | Host-driven live resize: paced `SetWindowRect` while the edge moves, crop drawn 1:1 (never stretched), guest rectangle kept inside the work area ("The Zen window", Resizing) |

Minimise ↔ Dock minimise, maximise ↔ zoom to work area, close ↔ `WM_CLOSE`
are mapped both ways. A minimised guest window stops producing frames; the
host keeps the last frame for the Dock thumbnail.

## Input model

Input still goes through the VM's virtual pointer and keyboard on display 1,
so the right guest window must be under the guest cursor and have focus.

1. **Pointer enter**: when the Mac cursor enters the `NSWindow` for HWND B,
   the host sends `PointerFocus{B}`. The agent raises B (and its owned/popup
   chain) to the top of the guest z-order **without activating**
   (`SetWindowPos(HWND_TOP, SWP_NOACTIVATE)`), so hover effects and scroll go
   to B. Transient windows are always above everything.
2. **Pointer move**: the host converts the event location to guest pixels and
   sends an absolute pointer event. Because of the 1:1 mapping this is the
   same coordinate the window occupies in the guest.
3. **Click / key focus**: when the `NSWindow` becomes key, the host sends
   `Activate{B}`; the agent calls `SetForegroundWindow` (the agent holds
   foreground-lock rights by being started with UIAccess or by the
   `AttachThreadInput`/`LockSetForegroundWindow` techniques; choose in M5).
   The host withholds the mouse-down until `Activated{B}` arrives or 30 ms
   pass, to avoid clicking through to the wrong window.
4. **Mac → Windows focus loss**: when a non-Seemless Mac window becomes key,
   the host sends `Deactivate`; the agent gives foreground to a hidden agent
   window so Windows apps see `WM_ACTIVATE(WA_INACTIVE)` and stop blinking
   carets, and held modifier keys are released.
5. **Cursor**: the guest cursor is never drawn, neither in the atlas nor as a
   bitmap on the Mac. The Mac pointer is the only pointer, and its shape
   follows the guest's cursor *kind* reported by the agent ("The Zen window",
   Pointer).
6. **Keyboard**: see 07 for the shortcut map (Cmd→Ctrl option, IME, dead keys).
7. **Elevated windows (UAC)**: the secure desktop cannot be captured or
   controlled by a normal process. Configure UAC to prompt on the normal
   desktop (`PromptOnSecureDesktop=0`) in the image, and run the agent with
   UIAccess (signed, installed in `Program Files`) so it can interact with
   elevated windows. Document the security trade-off.

## App identity on the Mac side

Windows from the same guest application should group like a Mac app:

- Group key: AppUserModelID if set, else process image path.
- v1: all guest windows belong to `Seemless.app`'s single Dock icon; the Dock
  menu and Window menu list them grouped by app, with icons.
- v2 (M6): **stub apps**. For each pinned Windows app, generate a tiny
  `.app` bundle in `~/Applications/Seemless/` (name, icon extracted by the
  agent, a launcher executable that messages `Seemless.app`). To get separate
  Dock tiles for *running* windows, the windows must be owned by a separate
  process: a small `SeemlessAppHost` process per guest app that receives its
  windows' IOSurface sub-rects and input over XPC from the main app. This is
  how separate Dock icons, Cmd-Tab entries and per-app Mission Control groups
  become possible. It is a significant piece of work; keep the `WindowBridge`
  API process-agnostic from the start so it can move out of process later.

## Mode transitions

| From → To | Trigger |
|-----------|---------|
| Seamless → Game | Agent reports a fullscreen-class window on display 1 that is foreground for more than 500 ms, or the user presses the game-mode shortcut |
| Game → Seamless | That window closes, loses fullscreen, or the user presses the release shortcut |
| Seamless ↔ Desktop | User toggle. Desktop mode shows scanout 0 in one window; the agent stops captures to save GPU |
| Any → "Agent lost" | No heartbeat for 3 s: host falls back to desktop mode with a banner, so the user is never left with no way to see Windows. **Z1 (2026-11-24):** with no desktop mode window yet, Zen ends with an alert "The Windows agent stopped responding." It also ends, silently, when QMP closes (the VM stopped) |

## Readiness and build order (2026-11-24)

| Piece | State |
|-------|-------|
| Desktop pixels on the Mac | **Ready (WP3.1).** `-display seemless` hands scanout 0 to the app as an IOSurface ring (Metal source with the 3D driver), plus cursor shape and pointer position. SeemlessKit's `DisplayClient` receives it. It supports up to 4 heads, enough for the atlas display (scanout 1) |
| Input to the guest | **Ready for absolute pointer and keys**: QMP `input-send-event` (S3 measured a ~1 ms round trip). `PointerFocus`/`Activate` need the agent |
| Window messages | **Schema and host client ready (WP4.1):** `WindowSnapshot/Added/Updated/Removed`, `PointerFocus`, `Activate/Activated`, `Deactivate`, `SetWindowRect`, `WindowCommand`, `HitTest`. The mock agent can script them today |
| Clipboard | **Schema ready (WP4.1)**; needs the agent (WP4.5) |
| Real window rectangles from Windows | **Missing.** Needs the Windows agent (WP4.2; its first build asks the owner to accept Microsoft's CRT/SDK licence for cargo-xwin) and `windows-model` (WP5.1) |
| Per-window pixels (tier 1, atlas) | **Not proven.** Spike S5: WGC on the Neptune driver, a second scanout, and whether `IsBorderRequired = false` works without a prompt |
| 3D driver in the guest | **Ready:** UTM v0.6, D3D11 at FL 11_1. The reset abort is fixed. VM `wp31` has it |

Tier 2's limit applies to Zen as it does to seamless. A crop shows whatever
is on top in the guest, so overlapping guest windows bleed into each other.
The "raise on pointer enter" rule hides that for the window under the
cursor, not for windows the user is only looking at. Tier 2 is good for
bring-up and as a fallback. Zen as a daily mode needs tier 1.

Build order:

1. **Z1, host Zen window on tier 2, driven by the mock agent.** Built
   2026-11-24. Mechanics are verified on the firmware VM: a mock-agent window
   at (40,30) 520×300 appeared as a chrome-less Mac window showing exactly
   that crop of the UEFI shell. Notepad acceptance is waiting for a Windows
   VM that boots. Code: `kit/Sources/SeemlessKit/Zen/`
   (`ZenWindowModel`, `ZenGeometry`, `GuestInput`, `GuestKeyMap`) and
   `app/Seemless/Zen/` (`ZenWindow`, `ZenCropView`, `ZenRenderer`,
   `ZenSession`). The entry point is Machine ▸ Enter Zen Mode (Preview)
   (Ctrl-Cmd-Z).
   - `WindowModel` (pure Swift, tests).
   - `ZenWindow`: the borderless subclass above.
   - `WindowBridge`, which crops scanout 0 per window with a Metal layer
     sampling the IOSurface sub-rect.
   - Absolute pointer and keys through QMP.
   - A mock-agent script whose window rectangles match a real Notepad
     placed at a known position in `wp31`.
   - Acceptance: Notepad appears as its own chrome-less Mac window, with the
     desktop hidden, and can be typed into.
2. **Z2, the real window feed:** WP4.2 (agent skeleton over vioserial) plus
   WP5.1 (enumeration, classification). Z1 then runs on real rectangles.
3. **Z3, input and focus correctness (WP5.3):** `PointerFocus` raise,
   `Activate` handshake, `Deactivate` to a hidden agent window, stuck keys,
   and native cursor shapes from `CursorShape` (the Windows pointer stays
   hidden from Z1 on).
   - **Z3b, clipboard (WP4.5):** text first, then RTF, HTML and images. It
     is gated on a Zen window or Mac app being key.
4. **Z4, tier 1 atlas (S5 → WP5.4):** overlapping windows stay separate,
   with real corner alpha.
   - **Window behaviour, host side** (pulled forward from Z5, 2026-11-24):
     - Mac corners, native drag from the Windows title bar (hover
       `HitTest`, `performDrag`, `SetWindowRect`) and native edge resize.
     - Dock minimise and restore, maximise following the guest, and Cmd-W
       / Cmd-M as `WindowCommand`.
     - **Verified on `fw`:** the guest-side sequence (move, minimise,
       restore, maximise, close) is followed with no echoes; rounded
       corners seen; real hover reached the agent as `HitTest`.
     - **Bug-testing round, 2026-11-24** (`docs/testing/seamless.md`):
       11 host bugs fixed on `fw`, then the owner tried a real Notepad on a
       fresh Windows VM (`zen1`). From that: moves became Mac-only, resize
       became live and unstretched, the guest window is kept in the work
       area, and the Windows cursor is hidden in the guest. Typing, clicks,
       Mac-only drag and live resize were tried by the owner on Notepad.
     - **Stand-in for the agent, testing only:** `proto/mock/zen-guest-helper.ps1`
       runs in the guest, reports one app's real windows and applies size and
       window commands over the user-mode network; `seemlessctl mock-agent`
       relays it with `"guestHelper": {"port": 47800}`
       (`proto/mock/notepad-live.json`, protocol `GuestHelperMessage`).
     - `seemlessctl mock-agent` scripts can enable
       `"windowManager": {"width": …, "height": …}`, a simulated Windows
       window manager (`SimulatedWindowManager`) that answers `HitTest` like
       a Windows 11 frame and applies `SetWindowRect` / `WindowCommand`.
5. **Z5, window life (WP5.5/5.7):** minimise, maximise and close mapping,
   transients as non-activating panels placed at their owner's offset.
6. **Z6, native identity (M6 stub apps):** Dock tile, menu-bar name and
   Cmd-Tab entry per Windows app.

## Edge cases to keep a test list for

Splash screens; windows that appear then immediately resize; borderless
custom-chrome apps (Electron, Steam, Spotify); layered/transparent windows;
always-on-top windows; system-modal dialogs; drag-and-drop feedback windows;
apps that create hundreds of hidden top-level windows; DPI-unaware apps
(bitmap-scaled by DWM, still captured correctly); UWP/WinUI apps hosted in
`ApplicationFrameHost` (cloaked CoreWindows); console windows (`conhost` vs
Windows Terminal); windows on other virtual desktops (cloaked); crash dialogs;
the Windows lock screen appearing unexpectedly; Print dialogs; file pickers.
