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
3. Options: install type (automatic / manual) and, for automatic, a
   Windows profile (`Lean` / `Lean, with Xbox` / `Fat` = stock; About
   popover explains each). Both are required with no preselection. Disk
   cap, RAM, shared folder
   (default: a new `~/Seemless` folder, not the whole home directory).
4. Build: staged progress with a collapsible log. Cancellable and resumable
   per stage.
5. Finish: launcher opens with the discovered apps; offer to install common
   launchers (Steam etc.) via winget.

**As built (WP3.4, Preview 1 P2, 2026-11-24):** `app/Seemless/WelcomeView.swift`
fills the window when the library is empty at launch (and from "Set Up
Windows…" on the empty library).

1. **Requirements** (`FirstRun.requirements`, kit): Apple silicon (not under
   Rosetta), macOS 26+, 25 GB free on the storage volume, the bundled
   components (QEMU stack, `image/` assets), the 3D guest driver (a warning
   only: without it Windows installs with basic graphics), and the user's
   own ISO with a link to Microsoft's download page. Seemless never ships or
   downloads Windows.
2. **ISO and profile:** drop or choose the ISO (inspected; Pro or the first
   supported edition), a required profile, the local account name. CPU,
   memory and disk use the defaults (changed later in Settings).
3. **Install:** `ImageBuilder` with the guest drivers (`GuestDrivers.locate`:
   `$SEEMLESS_GUEST_DRIVERS`, the bundle's `Resources/guest-drivers`, or
   `build/guest-drivers`) and an exported display (no QEMU window; "Watch
   the Install" opens it). Four stages from `ImageBuilder.Phase`, elapsed
   time and bytes written, a collapsible log, and plain-language errors with
   "Delete and Start Over".
4. **First start:** on success the VM starts in its desktop window with a
   bar explaining that Windows shows Microsoft's licence terms and that the
   person accepts them there. **The licence is never accepted by the app:**
   the welcome flow and the New VM sheet always build with the licence page
   shown (the sheet's "accept now" toggle is gone; only `seemlessctl image
   build --accept-windows-license` can skip it).

Not built: cancel/resume per stage, a shared folder choice, the launcher.

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

**As built for desktop mode (WP3.2, `KeyboardTranslator` in the kit):**

- Mac style (default): Command held sends nothing until a key is pressed
  with it; then the guest gets **right** Ctrl (never colliding with the real
  left Control) plus the key, for every key that is not reserved.
  Cmd-Left/Right → Home/End, Cmd-Up/Down → Ctrl-Home/End. Command pressed
  and released alone is a Windows-key tap (Start). AppKit drops key-ups
  while Command is held, so the window catches them with a local event
  monitor, and any key pressed with Command is released at the latest when
  Command goes up.
- PC style: Command is the Windows key; nothing is remapped.
- Reserved for macOS in both styles (go to the menus): Cmd-Q, Cmd-H,
  Cmd-Option-H, Cmd-M, Cmd-`, Cmd-, , Ctrl-Cmd-F, Cmd-Option-Esc (Cmd-Tab
  and Cmd-Space never reach the app). The app's own Cmd shortcuts (Cmd-R,
  Cmd-N, …) go to Windows while the desktop window is key.
- Display ▸ Send Keys: Ctrl-Alt-Delete, Ctrl-Shift-Esc, Alt-Tab, Alt-F4,
  Windows, Windows-L, Print Screen (`GuestKeyCombo`).
- The style is per VM (Display ▸ Keyboard, stored in `display.json`).
  Cmd-Q → Alt-F4 and game mode are not built.

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
| Run a Windows installer from the Mac ("Open in Seemless", built 2026-11-23) | Finder Open With (Seemless is an *alternate* handler for .exe/.msi) or Services > "Open in Seemless" → confirm sheet with VM picker (starts or resumes the VM) → `VMManager.launch` builds a read-only FAT32 USB drive labelled `SLRUN` (installer + `seemless-launch.txt` with a one-time request id) and hot-plugs it over QMP (`blockdev-add` + `device_add usb-storage`); drives older than 2 min are unplugged on the next send and all are cleared at the next start. Guest: `image/guest/SeemlessLauncher.ps1`, a logon task for every user (elevated, registered by `firstboot.cmd`), copies the installer to %TEMP% and starts it once per id; it accepts only a plain `.exe`/`.msi` file name. VMs without the task see the drive in Explorer and can run `Enable automatic installs.cmd` from it. CLI: `seemlessctl vm open <file>`. Replaced by the agent's `Launch` + shared folders in M4/S7 |
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

Machine ▸ Disconnect from Network / Connect to Network (⌥⌘I) unplugs or plugs
in the virtual cable while the VM runs. New VMs do their first setup offline
and connect once Windows reaches the desktop. Details: docs/02 "Network link".

## Quarantine

Owner request (2026-11-24): a VM can be **quarantined**. It then has no
connection to the Mac except keyboard, mouse and display, unless single
connections are switched on.

- **Chosen at creation:** in the New VM sheet (Isolation ▸ Quarantine this
  VM), with `seemlessctl vm create --quarantine`, or with `image build
  --quarantine`. It can't be added to an existing VM later.
- **Lifted only while stopped:** Settings ▸ Quarantine ▸ Lift Quarantine…
  shows a warning first; the CLI is `vm quarantine lift --yes`. The VM then
  gets every normal connection at its next start (owner's choice).
- **"Off" means no device** (owner's choice): the virtual hardware is left
  out of the QEMU command line, so the guest can't reach it at all, and
  changes apply at the next start (`QEMUCommand`, `VMConfig.allows`).

| Connection | Off | On |
|------------|-----|----|
| Network | No NIC, no port forwards | The VM's configured network |
| Guest agent | No virtio-serial device: no Zen mode, window information or agent shutdown | Agent channel |
| Clipboard Mac → Windows | — | Allowed; needs the agent |
| Clipboard Windows → Mac | — | Allowed; needs the agent |
| Files | No attached disks or ISOs; Open in Seemless refused | Attach media, Open in Seemless; drag and drop and shared folders (need the agent) |
| Sound | No audio device | Sound out (QEMU's `usb-audio` is playback only: there is no microphone device to switch) |

Always on: USB keyboard and tablet, the display, the NVMe system disk and
the TPM. Drives given for one launch only (the image build's installer and
setup disk) are not attached media and still work, so a quarantined VM can
be installed.

New features that move data between Windows and the Mac (clipboard WP4.5,
drag and drop, shared folders, notifications, `OpenOnHost`) must check
`VMConfig.allows(_:)` on the host before moving anything. In a quarantined
VM, a connection field the config doesn't name decodes as off, so a new
connection is never switched on by accident.

CLI: `seemlessctl vm quarantine show|set <connection> on|off|lift`.
Verified (2026-11-24): a quarantined VM booted with only the display, NVMe and
USB controller on PCI (no virtio-net or virtio-serial) and no `usb-audio`, and
`vm network` reported no network.

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
