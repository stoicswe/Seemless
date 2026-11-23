# 05 — Seamless mode

Each Windows top-level window is mirrored by one borderless `NSWindow`. The
Windows desktop, taskbar and wallpaper are never shown.

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
- The usable work area (excluding Mac menu bar and Dock) is pushed to the
  guest with `SPI_SETWORKAREA` so maximise fills the right region.
- **Guest z-order is invisible** to the user in tier 1, so the agent is free
  to reorder guest windows for input purposes (below). Mac z-order is the only
  one the user sees.

### Move and resize

| Phase | Behaviour |
|-------|-----------|
| v1 | Guest-driven. The user drags the Windows title bar; Windows moves the window; the agent streams `LOCATIONCHANGE`; the host moves the `NSWindow` with animations disabled. Expect 1–2 frames of lag |
| v2 | Host-driven move. On mouse-down the agent hit-tests (`WM_NCHITTEST` result `HTCAPTION`); the host then moves the `NSWindow` natively and sends coalesced `SetWindowPos` to the guest, final position on mouse-up. Removes lag and enables macOS window snapping/tiling |
| Resize | Guest-driven in both phases (the app must re-layout). The host resizes the `NSWindow` when the new size *and* the first frame at that size arrive, to avoid stretching |

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
5. **Cursor**: the guest cursor is not drawn in the atlas. QEMU forwards
   cursor shape changes; the host sets the matching `NSCursor`.
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
| Any → "Agent lost" | No heartbeat for 3 s: host falls back to desktop mode with a banner, so the user is never left with no way to see Windows |

## Edge cases to keep a test list for

Splash screens; windows that appear then immediately resize; borderless
custom-chrome apps (Electron, Steam, Spotify); layered/transparent windows;
always-on-top windows; system-modal dialogs; drag-and-drop feedback windows;
apps that create hundreds of hidden top-level windows; DPI-unaware apps
(bitmap-scaled by DWM, still captured correctly); UWP/WinUI apps hosted in
`ApplicationFrameHost` (cloaked CoreWindows); console windows (`conhost` vs
Windows Terminal); windows on other virtual desktops (cloaked); crash dialogs;
the Windows lock screen appearing unexpectedly; Print dialogs; file pickers.
