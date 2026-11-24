# S3 — Display export

Status: **done** (2026-11-23; Metal path verified in WP3.1, 2026-11-24, see the end).
D4 decided: our own small backend, not `-display dbus`.

Host: M3 MacBook Pro, built-in Liquid Retina XDR (ProMotion, up to 120 Hz),
macOS 27.3. QEMU: `utmapp/qemu` 8ab298bc (the S1 pin) plus the spike patch,
built separately into `build/s3/` so `build/prefix` (used by S2) was not
touched. No new external sources: only Apple frameworks (IOSurface, Metal,
ScreenCaptureKit), so `scripts/versions.lock` and `THIRD_PARTY.md` are
unchanged.

## Results

| Question | Answer | Evidence |
|----------|--------|----------|
| Is `-display dbus` in our build? | Yes (S1) | `-display help` |
| Can `-display dbus` drive the GL device on macOS? | **No.** `gl=on`/`gl=es` stops at start-up with `egl: not available on this platform` (`egl_init()` only has Linux GBM and Windows branches). Without `gl`, `virtio-ramfb-gl` refuses to start (`The display backend does not have OpenGL support enabled`) | runs below |
| Could it with a small patch? | Not small. In `ui/dbus-listener.c` the GL scanout path exports DMABUF (Linux) or D3D11 shared textures (Windows) and has **no macOS branch**: `dbus_scanout_texture()` compiles to nothing on macOS. The 2D map path needs a memfd `share_handle` (none on macOS), so it falls back to copying whole frames inside D-Bus messages. D-Bus also cannot carry Mach ports, so an IOSurface would need a side channel anyway. We would be writing the backend inside dbus plus a D-Bus client (glib) in the app | source read |
| What does the GL scanout look like in QEMU on macOS? | virglrenderer hands QEMU a **native `MTLTexture`** for the guest's scanout (`SCANOUT_TEXTURE_NATIVE_TYPE_METAL`, `virgl_scanout_native_blob`). `ui/cocoa.m` blits it once per `RESOURCE_FLUSH`; UTM's `ui/spice-display-metal.m` blits it into an IOSurface for CocoaSpice | `hw/display/virtio-gpu-virgl.c`, `ui/cocoa.m` |
| IOSurface hand-off method | **Mach send rights**: QEMU calls `IOSurfaceCreateMachPort` and sends the rights as port descriptors to a receive port the app checks in with `bootstrap_check_in(bootstrap_port, "app.seemless.<…>")`; QEMU finds it with `bootstrap_look_up`. Works for an ad-hoc name in the user's GUI session, no launchd plist. Chosen over UTM's `kIOSurfaceIsGlobal` + `IOSurfaceID`, which lets any local process read the guest screen | spike |
| Reconnect | App quit → QEMU's next send fails `MACH_SEND_INVALID_DEST` (0x10000003), it drops the port and looks the name up again every 250 ms; a restarted viewer got the surfaces again with no QEMU restart | `qemu.log` |
| Input back | **QMP `input-send-event`** (key qcodes, `abs` axes 0…32767 for `usb-tablet`, buttons, wheel). No QEMU change needed. Round trip p50 ~1 ms | viewer stats |
| Scanout 0 in a Metal view at display refresh | Yes: UEFI firmware and the Windows desktop shown in `CAMetalLayer`, presented from a `CADisplayLink` or on frame arrival | screenshots below |
| Click the Start button | **Yes.** Owner's Lean VM (build 26300, booted through a throwaway overlay) auto-logged on as `Seemless`; with Start closed, a click sent through the viewer's AppKit handler (`NSWindow.sendEvent` → `mouseDown` → view-to-guest mapping → QMP) opened the Start menu | `spikes/S3-display/evidence/windows-start-*.png` |
| Added latency vs `-display cocoa,gl=es` | **+10 ms (display link), +6 ms (draw on arrival)** at p50, key → pixels on glass. Table below | `evidence/latency/` |

### Latency

Method (`spikes/S3-display/measure.sh`, one run per row): firmware front
page, 40 × alternating Down/Up sent over a second QMP socket.
`S3Latency` watches the window with ScreenCaptureKit; one sample =
`SCStreamFrameInfo.displayTime` of the first captured frame whose pixels
changed, minus `mach_absolute_time()` just before the QMP write. Same
method, same guest, same window size (1 device pixel per guest pixel, like
cocoa) for both backends. This includes the guest's own keyboard polling
and the ramfb refresh timer (30 ms), which is why the absolute numbers are
large: only the **difference** is the cost of our path.

| Run | p50 | mean | p90 | min | max |
|-----|----:|-----:|----:|----:|----:|
| cocoa-1 | 45.9 | 46.9 | 58.1 | 31.0 | 69.9 |
| cocoa-2 | 46.6 | 46.6 | 53.3 | 33.3 | 56.6 |
| seemless, display link (1) | 56.0 | 57.1 | 73.1 | 36.1 | 81.0 |
| seemless, display link (2) | 57.4 | 57.5 | 70.3 | 35.8 | 84.2 |
| seemless, draw on arrival (1) | 53.8 | 54.2 | 67.0 | 33.4 | 82.0 |
| seemless, draw on arrival (2) | 51.5 | 52.3 | 63.2 | 35.8 | 79.9 |
| seemless, on arrival, 2 drawables | 56.7 | 55.7 | 70.1 | 31.5 | 94.8 |

(ms, n = 40 each, no misses.) cocoa ≈ 46.7 mean; ours ≈ 57.3 with the display
link (+10.6) and ≈ 53.2 drawing on arrival (+6.5). Two drawables did not help.

Where our time goes (viewer's own stamps, all `mach_absolute_time`, p50 over
~860 frames per run, 2D path):

| Stage | display link | on arrival |
|-------|------:|------:|
| QEMU update → pixels in IOSurface (CPU copy, 800×600) | 0.09 | 0.08 |
| Mach message to the app | 0.01 | 0.02 |
| Wait for the display link | 4.6 | 0.03 |
| Draw + present → `presentedTime` | 16.1 | 20.6 |
| **Total, QEMU update → on glass** | **23.4** | **20.8** |

The hand-off itself (copy + Mach message) costs ~0.1 ms. The rest is
presenting a windowed `CAMetalLayer` through WindowServer (2–3 refreshes at
120 Hz), and waiting for the next display-link tick. cocoa presents
immediately after its refresh timer, so it avoids the tick wait; the
remaining ~6 ms with on-arrival drawing is presentation, which we did not
chase further (see Open).

Windows desktop (Basic Display, 800×600, 2D path), on-arrival mode: QEMU
update → on glass p50 20.5 ms, p99 25.8 ms over 3555 frames.

## Method

1. Read `ui/dbus*.c`, `ui/egl-helpers.c`, `ui/cocoa.m`,
   `ui/spice-display*.{c,m}`, `hw/display/virtio-gpu-virgl.c` at the pin and
   ran `-display dbus` with the production device.
2. Wrote `-display seemless,gl=es,service=NAME` (`ui/seemless.m`, ~510
   lines, plus a QAPI enum/struct and one meson line):
   `patches/qemu/spike-S3-ui-seemless.patch`. It keeps a ring of three
   IOSurfaces sized to the scanout; sends them once per size/format change
   (generation number) and then one inline message per frame
   (index, serial, rect, timestamps; 80 bytes with the header). Sources:
   - 2D console surface (firmware, ramfb, Windows Basic Display): CPU copy
     from the pixman surface; `SEEMLESS_REFRESH_MS` changes the refresh timer.
   - virgl native Metal scanout: one GPU blit into the ring slot at
     `dpy_gl_update` (RESOURCE_FLUSH), one in flight, following cocoa's
     rules for when the guest buffer is valid; the frame message is sent from
     the command buffer's completion handler.
   - Sends use `MACH_SEND_TIMEOUT` 0: a stuck app drops frames, never blocks
     QEMU's main loop.
   - GL contexts for virgl come from ANGLE's EGL display
     (`qemu_egl_init_dpy_cocoa`), surfaceless, like `ui/dbus.c`.
3. `spikes/S3-display/` (Swift package, throwaway):
   - `S3Viewer`: checks in the Mach name, validates each message (size,
     descriptor types, and the IOSurface's own width/height/format against
     the header), wraps the surfaces as `MTLTexture`s, draws into a
     `CAMetalLayer`, sends AppKit keyboard/mouse to QMP. Scripted commands on
     stdin (`click`, `nsclick`, `key`, `nskey`, `shot`, `stats`).
   - `S3Latency`: the ScreenCaptureKit measurement above.
   - `run.sh`, `view.sh`, `measure.sh`.
4. Windows: the owner's `Windows 11` VM booted through a qcow2 overlay in
   `build/s3/win/` with copies of its EFI vars and TPM state; nothing of the
   owner's was written. Its base disk was open read-only while the spike VM
   ran (~5 min).

## What was seen and what was not

- Seen (window captures with `screencapture -l` and the viewer's IOSurface
  dumps): firmware shell and front page in our window; typed commands
  executing; the Windows desktop; Start closed, then open after our click.
- Real HID input was **not** tested: posting `CGEvent`s needs Accessibility
  permission, which this session does not have. Input was tested through
  the viewer's own AppKit handlers (`NSWindow.sendEvent`) and through QMP.
- The **Metal (GL) path was not run**: the Windows image has no 3D driver
  yet (S2 in progress), so every frame took the 2D path (`source=1`). The
  code compiles and follows cocoa's logic but needs a guest with the
  viogpu3d driver. A GL-only scanout (no native Metal texture) is logged
  and ignored by the spike.
- Cursor shape/position (`dpy_mouse_set`, `dpy_cursor_define`) not
  exported: with `usb-tablet` and Basic Display, Windows draws its own
  pointer into the framebuffer.
- Only scanout 0. `max_outputs=2` multi-scanout is a loop over consoles in
  the same design; untested (S5).

## Recommendation

**Write our own `ui/seemless` backend (D4), along the lines of the spike.**
dbus cannot drive the GL device on macOS, has no macOS texture export, and
cannot pass IOSurfaces; fixing that is the same work as our backend plus a
D-Bus dependency on both sides. The spike's design holds up: Mach-port
IOSurface hand-off via a bootstrap name, ring of three surfaces, input over
QMP, and the hand-off itself costs ~0.1 ms.

For the product (M3):

1. Draw on frame arrival by default (−4 ms vs the display link) and keep
   the display link only for pacing when frames arrive faster than refresh.
2. Make the scanout ring and the frame message part of the patch series
   (`patches/qemu/0001-ui-seemless-…`), keep it out of virtio-gpu code
   (it is: one new file, QAPI, meson).
3. Replace the stdin/global-name rendezvous with a per-VM name the helper
   chooses (`app.seemless.display.<vm-uuid>`), and add `FrameAck`
   back-pressure so QEMU never writes a slot the app is reading (today the
   ring of three only makes that unlikely).
4. Add cursor messages (needed once the 3D driver uses a hardware cursor)
   and the second scanout (S5).
5. Input can stay on QMP for v1; a dedicated channel only if QMP latency
   under load turns out to matter (p50 ~1 ms, p99 up to 59 ms in one
   long firmware run while QEMU was busy, worth watching).

## Open

- Run the Metal path with S2's driver; record copy cost for a 4K scanout.
- The remaining ~6 ms vs cocoa is in presentation; try
  `presentsWithTransaction`, `displaySyncEnabled = false` and the
  `CAMetalDisplayLink` API before blaming WindowServer.
- Rerun the comparison at the 3D path's frame rate (60–120 fps); the 2D
  ramfb path is limited to the 30 ms refresh timer in both backends.

## Follow-up: WP3.1 (2026-11-24)

The spike became `patches/qemu/0001-ui-seemless-display-backend.patch`
(protocol v1 in the header: multi-client CONNECT, same-uid check, ring per
scanout, FRAME, DISABLE, CURSOR, MOUSE, ACK back-pressure, SET_SIZE), applied
by `scripts/build-deps.sh` (`apply_patches qemu`). Host side:
`SeemlessKit.DisplayClient` + `CSeemlessDisplay`, `LaunchOptions.Display.exported`
(`vm run --export-display`), `seemlessctl screenshot` and `display info|size`.

**The Metal path ran.** Fresh Lean VM `wp31` (`--root build/s3/root`, viogpu3d
injected offline with `image build --drivers`, licence accepted by the owner
at first start), started with `--export-display`:

| Check | Result |
|-------|--------|
| Early boot (firmware, Windows Boot Manager) | 800×600, `source=2d` |
| Desktop with the 3D driver | 1024×768, `source=metal`, 100 % non-black; QMP `screendump` of the same moment is all black |
| `display size --width 1280 --height 800` | guest switched to 1280×800 (taskbar re-laid out), still `metal` |
| Pointer moved by QMP | visible in the frame at the expected place |
| CURSOR / MOUSE events | none: viogpu3d v0.6 draws a software cursor into the scanout |

Screenshots (not committed: Microsoft wallpaper, UTM firmware logo):
`build/s3/shots/{fw,early-boot,desktop-3d,desktop-qmp,desktop-1280-b}.png`.

### Screenshots in the app (2026-11-24)

`VMManager.screenshot(_:scanout:)` is the one implementation for the app and
`seemlessctl screenshot`. It uses the exported IOSurface when there is one,
else QMP `screendump`, and flags a black screendump (the 3D driver case). The
app has a camera button for a running VM, **Machine ▸ Take Screenshot**
(⇧⌘S) and **Start without Window** (exported display). It saves to the macOS
screenshot location (`com.apple.screencapture location`, else the Desktop)
as `Seemless <vm> <date> at <time>.png` and shows a preview sheet (Copy, Show
in Finder). Checked with the app's window captured during
`SEEMLESS_OPEN=screenshot:<vm>`; the buttons were not clicked by a person.

### `wp31` broke on its third boot

After the resize test, `wp31` was shut down cleanly by the guest (ACPI). The
next start (`--export-display`) hung in the boot manager: firmware screen,
only vCPU 0 running at a fixed PC, no renderer activity, for more than 9 minutes.
After one forced power-off, Windows booted into Startup Repair ("couldn't be
repaired"), which is `admfix`'s symptom without any reset series. Suspect: Windows'
Fast Startup (a hibernate) resuming with viogpu3d loaded, perhaps after the
resolution change. This is S6's open question; the display export only
showed it. Not investigated further.

**Explained in `S6b-hibernate-resume-crash.md`:** Fast Startup turned the
ACPI shutdown into a hibernate, and the resume crashed with viogpu3d loaded.
The resize was not involved. New images turn Fast Startup off in
`firstboot.cmd`.
