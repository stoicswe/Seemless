# 07 — Host app and macOS integration

## App structure

`Seemless.app` is a regular (Dock-visible) app, Swift 6, SwiftUI for chrome
and AppKit for everything window- and event-level.

| Module | Role |
|--------|------|
| `AppCoordinator` | Owns the VM lifecycle state machine, mode switching, error surfaces |
| `Onboarding` | First-run flow: explain → pick ISO → choose size/RAM → build image (progress from 03) → done |
| `WindowBridge` | `WindowModel` diffs → `GuestWindowController`s (one `NSWindow` each); input routing; focus policy |
| `DisplayRenderer` | Metal: scanout IOSurfaces → layers (04) |
| `DesktopWindow` / `GameWindow` | Single-surface modes |
| `Launcher` | Start-menu replacement: searchable grid/list of Windows apps, Spotlight-style hotkey |
| `MenuBarExtra` | Status item: VM state, mode toggle, tray icons, pause/resume, "Show Windows desktop", diagnostics |
| `Integration/*` | Clipboard, drag and drop, files, notifications, Dock, shortcuts, controllers, audio routing |
| `Settings` | CPU/RAM, shared folders, keyboard mapping, graphics backend, pause policy, updates |

All non-UI logic belongs in `SeemlessKit` so `seemlessctl` and tests can
drive it.

## User flows

### First run

1. Welcome: what Seemless does, what the user needs (a Windows 11 ARM64 ISO,
   ~25 GB free, optionally a Windows licence).
2. ISO: drag-and-drop or "Get it from Microsoft" (opens the download page in
   the browser). Validate (03 stage 2) and show build/edition/language.
3. Options: disk cap, RAM, recipe (`Default` / `Gaming`), shared folder
   (default: a new `~/Seemless` folder, not the whole home directory).
4. Build: staged progress with a collapsible log. Cancellable and resumable
   per stage.
5. Finish: launcher opens with the discovered apps; offer to install common
   launchers (Steam etc.) via winget.

### Daily use

- Clicking the Dock icon or the hotkey opens the launcher. If the VM is
  suspended or stopped it starts in the background; the launcher shows cached
  apps immediately and queues the launch.
- Closing the last Windows window does not stop the VM; the pause policy does.
- Quitting `Seemless.app` suspends (or shuts down, per setting) the VM.

## Guest window presentation

`GuestWindowController`:

- `NSWindow` style: borderless, resizable off (guest drives size),
  `hasShadow = true`, `isOpaque = false`, `backgroundColor = .clear`,
  `collectionBehavior` = managed + participates in cycle + fullScreenNone.
  Override `canBecomeKey/Main` to true for app windows, false for transients.
- Content: one `CALayer`/`CAMetalLayer` sampling the window's atlas rect.
- Title (for Mission Control/Window menu/accessibility) mirrors the guest
  title. `representedURL` is unset.
- Owned dialogs use `addChildWindow(_:ordered: .above)`.
- Transients use `NSPanel` with `.nonactivatingPanel`, level `.popUpMenu`.
- Accessibility v1: expose title and role only. Bridging UI Automation to
  the macOS accessibility tree is a known gap; list it as future work.

Shadow note: macOS derives the shadow from window alpha. Windows 11 already
draws its own soft shadow outside the extended frame bounds; capture is
cropped to the extended frame so only the macOS shadow shows.

## Keyboard

| Topic | Behaviour |
|-------|-----------|
| Delivery | `NSEvent` key down/up → QEMU key events (USB HID usage codes, layout-independent). The guest's keyboard layout is set to match the Mac's input source, so characters come out right |
| Modifier mapping (default "Mac style") | Cmd→Ctrl for C/V/X/Z/A/S/F/T/W/N/P/O and friends, so Mac muscle memory works. Option→Alt. Ctrl→Ctrl. Fn/Globe unchanged. Right-Option→AltGr |
| Alternative ("PC style") | Cmd→Win, Option→Alt, Ctrl→Ctrl, no remapping |
| Reserved for macOS | Cmd-Tab, Cmd-Space, Cmd-`, Cmd-H, Cmd-M, Cmd-Q (Cmd-Q on a guest window sends Alt-F4 to that window, with a setting), Mission Control keys |
| Game mode | No remapping; all keys including Cmd go to the guest except the release shortcut (Ctrl-Option-Cmd or user-defined) |
| Text input / IME | v1: guest IME only (user types with Windows IME for CJK). v2: host IME via `NSTextInputClient` and Unicode injection (`SendInput` `KEYEVENTF_UNICODE` through the agent). Dead keys follow the same split |
| Stuck keys | On key-window loss, send key-up for everything held |

## Pointer

- Seamless/desktop: absolute coordinates (05), wheel with pixel-precise
  deltas converted to `WHEEL_DELTA` fractions (high-resolution scrolling),
  horizontal scroll, back/forward buttons.
- Trackpad gestures: pinch → Ctrl+wheel; smart zoom ignored; three-finger
  system gestures stay with macOS.
- Game mode: relative mouse with pointer capture (08).

## Clipboard

`NSPasteboard` change-count polling (250 ms while a guest window is key, plus
on activation) ↔ `ClipboardOffer`. Data is fetched lazily on paste
(`NSPasteboardItemDataProvider` on the Mac side, delayed rendering in the
guest). Privacy rule from 06 applies. Honour
`org.nspasteboard.ConcealedType` (password managers): never forward.

## Files

| Feature | Mechanism |
|---------|-----------|
| Shared folders | virtiofs (`vhost-user-fs` is Linux-only, so this depends on the QEMU fork's built-in virtiofs/9p support on macOS: spike S7). Fallbacks: QEMU 9p + a Windows 9p client, or host SMB served from a loopback-only user-space SMB server. Guest side maps a drive letter (`Z:`) and redirects known folders optionally |
| Default share | `~/Seemless` ↔ `Z:\`. Desktop/Documents/Downloads sharing is opt-in per folder |
| Open Mac file in Windows app | Stub apps declare document types (from the guest's file associations, queried by the agent). Opening a file under a shared folder → `Launch{app, files:[Z:\...]}`. Files outside any share: offer to add the folder or copy to a staging share |
| Open Windows link in Mac browser | Optional: register a tiny guest "browser" (`SeemlessOpen.exe`) as default handler for http/https/mailto → `OpenOnHost` |
| Drag and drop | Mac → Windows: files under shares are passed as paths; others are staged. Windows → Mac in M6 |
| Downloads | Guest Downloads known-folder redirected to `Z:\Downloads` (opt-in) |

## Notifications

Agent listens with `UserNotificationListener` (needs user consent in the guest
once; pre-grant via registry in the image if possible) or falls back to
watching toast windows. Host posts `UNUserNotificationCenter` notifications
attributed with the app name and icon; clicking one activates the source app
window.

## Dock, launcher, Spotlight

- v1: one Dock icon. Dock menu lists running Windows apps and windows.
  Launcher window is the Start menu.
- M6: stub `.app` bundles (05) in `~/Applications/Seemless/` so Windows apps
  appear in Spotlight, Launchpad and can be kept in the Dock. Icons come from
  the agent at 512 px (fall back to upscaled 256). Stubs are regenerated on
  `AppsChanged` and removed on uninstall.
- Tray icons: shown in the `MenuBarExtra` popover with left/right-click
  actions forwarded (`TrayInvoke`).

## Audio

- Output: QEMU `coreaudio` backend to the default output device; follow
  device changes. Target round-trip under 40 ms; measure in M7.
- Input: off by default; microphone permission requested when the user
  enables it. Per-VM mute in the menu bar extra.
- Each guest app is not a separate audio source to macOS in v1.

## Networking

Slirp user networking by default (02). Show the guest's reachability in
diagnostics. vmnet shared/bridged is a later, entitlement-dependent option.
Host → guest services (e.g. local dev servers) via explicit port forwards in
settings (`hostfwd`).

## Controllers and other devices

- Game controllers: `GameController.framework` on the host → emulated Xbox
  360 pad in QEMU (02 patch list) → Windows inbox XInput driver. Rumble back
  via the same device. Up to 4 pads.
- USB passthrough (generic): QEMU `usb-host` via libusb works for many
  devices on macOS but conflicts with macOS class drivers. Later; UI should be
  "Connect to Windows" per device.
- Camera, Bluetooth, printers: out of scope for v1. Printing can go through
  "Print to PDF" into the shared folder.

## Power and resources

- Pause policy: pause the VM after N minutes with no guest windows and no
  audio (default 5; never while a download/installer is detected via agent
  CPU/network heuristics is a later refinement). Resume on launch.
- On Mac sleep: pause first; on wake: resume and `TimeSync`.
- Low battery / Low Power Mode: reduce vCPU QoS and cap frame rate.
- Memory pressure notifications: balloon the guest (M7).

## Diagnostics

One "Copy diagnostics" action producing a zip: `VMConfig`, QEMU argv and
stderr, QMP event log, agent log (pulled over bulk), `GuestInfo`, render
server logs, last scanout screenshots, app and OS versions. No user file
contents. This is also what an implementing agent should read first when
something fails.
