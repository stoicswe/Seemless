# 04 — Graphics

This is the hardest part of the product and the one where we deliberately do
**not** start from scratch. As of UTM 5.0 (2026) there is a working,
open-source Direct3D path for Windows 11 ARM guests on QEMU on macOS. We adopt
it, pin it, and spend our effort on presentation (seamless, game mode) and
performance.

## The adopted stack

```
Guest (Windows 11 ARM64)                         Host (macOS)
────────────────────────────────                 ─────────────────────────────────────
Game / app  (x64 via Prism, or ARM64)
  │  D3D11 API
d3d11.dll / dxgi.dll  (Microsoft, untouched)
  │  D3D11 DDI
Triton UMD                                       QEMU virtio-gpu (neptune capset)
  │  DDI → D3D11 API calls, DXBC → DXContainer     │
Neptune encoder (serialises COM calls)           virglrenderer
  │  shared-memory ring                            │ one virgl_render_server per context
viogpu3d KMD (WDDM 2.x) ── virtio-gpu ─────────►  Neptune decoder
                                                   │ real D3D11 calls
DWM composes with shared textures                D3D11: DXMT        D3D12: vkd3d-proton → MoltenVK
  │                                                │
scanout resource  ───────────────────────────►   Metal  →  IOSurface  →  Seemless.app
```

Key properties, from UTM's Neptune and Triton write-ups:

- Triton is a real WDDM user-mode driver, so Microsoft's `d3d11.dll` stays in
  place. Nothing is injected per application, and **DWM itself is
  GPU-accelerated**, which is what makes per-window capture cheap (05).
- The KMD derives from the community Venus KMD work (anonymix007's branch of
  `kvm-guest-drivers-windows`); the UMD↔KMD interface is the same as Venus.
- State tracking happens on the host, off the guest's few vCPUs. UTM measured
  Neptune beating DXVK-over-Venus on Fire Strike, Heaven, FFXIV and Civ VI on
  a Linux host for that reason.
- Cross-process texture sharing on macOS uses `shm_open` memory wrapped as
  `MTLBuffer` (`newBufferWithBytesNoCopy`), relying on unified memory. Shared
  textures are linear, so they are memory-hungry; keep their count small.
- Host backends UTM ships: **DXMT** (D3D11, open source, arm64) and
  **D3DMetal** (D3D11 + D3D12, Apple proprietary, x86_64 only so the render
  server runs under Rosetta; faster than DXMT in UTM's test). We bundle DXMT
  and plan our own D3D12 backend on MoltenVK (below); D3DMetal is optional.
- UTM labels the driver experimental: limited game compatibility, possible
  guest instability, fresh install recommended.

Source locations are in [11-references.md](11-references.md).

## API coverage plan

| API | Path | When |
|-----|------|------|
| D3D11 (and D3D10/9 apps that Windows maps onto the D3D11 driver via its own layers) | Triton → Neptune → DXMT | M0 spike, M3 product |
| D3D12 | Guest D3D12 UMD + Neptune D3D12 protocol (upstream-dependent) → **vkd3d-proton → MoltenVK → Metal** on the host. See "D3D12 via MoltenVK" | S8 in M0, product in M7 |
| D3D9 | Windows runs D3D9 on WDDM drivers through its D3D9-on-12/‑on‑11 mapping only if the driver exposes what it needs; otherwise ship DXVK-style d3d9→d3d11 wrappers per-app as a fallback. Investigate in M7 | M7 |
| Vulkan | Venus ICD for Windows guests (community KMD work) → virglrenderer Venus → MoltenVK | M7, optional |
| OpenGL | Not accelerated initially (Microsoft's GLOn12 needs D3D12). Software fallback | Later |
| Video decode (DXVA) | Not in scope initially; software decode | Later |

## D3D12 via MoltenVK

Owner decision (2026-11-23): D3D12 calls are mapped through MoltenVK, so the
whole D3D12 path is open source, bundled, native arm64, and needs neither
Rosetta nor anything the user must fetch from Apple.

```
Guest D3D12 app → d3d12.dll (Microsoft) → D3D12 UMD → Neptune (D3D12 calls)
   → virtio-gpu → virgl_render_server → vkd3d-proton (D3D12 → Vulkan)
   → MoltenVK (Vulkan → Metal) → Metal
```

This mirrors what UTM's Neptune post sketches for Linux hosts (vkd3d-proton
listed as the future D3D12 host backend next to DXVK), with MoltenVK as the
Vulkan driver on macOS.

What has to exist, and who builds it:

| Piece | State | Owner |
|-------|-------|-------|
| Neptune D3D12 protocol + guest D3D12 UMD | Announced by UTM as the next phase; not shipped as of 2026-11-23 | Upstream first; **we write our own if necessary** (see "Guest D3D12 driver" below) |
| vkd3d-proton as a native macOS arm64 library | Upstream targets Wine/Proton on Linux; a native (non-Wine) build with the macOS WSI pieces removed or stubbed is our work, similar to what UTM did for DXMT (`dxmt-native`) | Us (S8, WP7.5) |
| Cross-process shared textures and fences for the D3D12 backend | Required by Neptune/Triton (DWM composition, swapchains). Implement the same way as for DXMT: `shm_open`-backed `MTLBuffer`s, exposed through MoltenVK's Metal interop (`VK_EXT_metal_objects`) | Us (WP7.5) |
| MoltenVK feature coverage | **The main risk.** vkd3d-proton assumes a modern desktop Vulkan driver. MoltenVK does not implement all of Vulkan, and UTM reports even DXVK (D3D11) on MoltenVK as unstable | S8 produces the exact gap list; then patch MoltenVK/vkd3d-proton, or pick KosmicKrisp where available |

Rules for this path:

- **S8 runs before any integration work.** It needs no VM: build vkd3d-proton
  natively, run its test suite and D3D12 demos against MoltenVK on this Mac,
  and list every required-but-missing Vulkan feature or extension. Do not
  guess the list from memory.
- Keep the Vulkan driver swappable (ICD selection by environment): MoltenVK
  is the default, KosmicKrisp (Mesa's Vulkan-on-Metal; needs macOS 26, which
  every supported Mac has; experimental
  per UTM 5.0 notes) is the alternative to test in S8.
- D3D11 stays on DXMT. Do not route D3D11 through DXVK → MoltenVK; UTM tried
  it and found it unstable, and DXMT avoids one translation layer.
- MoltenVK is shared with Venus (Vulkan for the guest), so there is one
  Vulkan driver to pin, patch and ship.
- If S8 ends in "no-go", the decision goes back to the owner with the gap
  list; the options then are patching MoltenVK, waiting on KosmicKrisp, or
  D3DMetal-only D3D12.

### Guest D3D12 driver: upstream first, our own if necessary

Owner decision (2026-11-23): we start now on everything that does not depend
on the guest D3D12 driver, use upstream's driver if it arrives, and write our
own if it does not.

Work that starts immediately and is needed either way: S8, the native
vkd3d-proton build, and the host D3D12 backend with shared textures/fences.
The host backend can be exercised without any guest driver by replaying
D3D12 calls from a host-side test harness.

**Trigger for writing our own** (check at the end of M5, and again whenever
upstream publishes D3D12 work):

- upstream has no public D3D12 UMD branch that renders a triangle in a
  Windows guest, or
- upstream's driver exists but is tied to D3DMetal-only behaviour that
  vkd3d-proton/MoltenVK cannot satisfy.

Before starting, open an issue/discussion with UTM's maintainers stating the
intent, to avoid duplicate work and to agree on the wire protocol.

**Design if we build it** — the same shape as Triton, one API up:

| Layer | Approach |
|-------|----------|
| KMD | Reuse the existing viogpu3d KMD unchanged. The UMD↔KMD interface is API-agnostic (rings, blobs, contexts). Any D3D12-specific need (e.g. WDDM 2.x GPU virtual address / residency callbacks) is the first thing to investigate |
| UMD | A D3D12 user-mode driver implementing the D3D12 DDI, registered alongside Triton in the same driver package. Like Triton, it maps each DDI call back to the equivalent D3D12 API call rather than inventing an intermediate bytecode |
| Shaders | D3D12 hands the driver DXIL (and DXBC for older shader models). Forward the container to the host unchanged; vkd3d-proton already consumes both |
| Wire protocol | Extend Neptune's code generator (`neptune-protocol`, MIDL → C wire format) with `d3d12.idl`. Do not hand-write encoders. Keep the encoding compatible with upstream's conventions so the work can be upstreamed or swapped for theirs |
| Host | Neptune decoder dispatches into vkd3d-proton (already built in WP7.5) |
| Presentation | DXGI swapchains and DWM sharing go through shared textures/fences, as for D3D11. D3D11 (DXMT, Metal directly) and D3D12 (MoltenVK) surfaces must interoperate: both end in `shm_open`-backed Metal buffers |

Anchors, following the method UTM documented for Triton (read their bring-up
notes first): model on a proven design (Triton and Venus), give every step a
terminal-checkable pass condition, and keep a known-good reference (the same
D3D12 test running natively on vkd3d-proton on the host) to compare against.

Bring-up ladder, each rung a work package:

1. Driver loads; `D3D12CreateDevice` succeeds; `dxdiag` reports feature level.
2. Clear a render target and read it back (no presentation).
3. Triangle with a DXIL shader, off-screen, image compared with the host
   reference.
4. Swapchain present through DXGI/DWM.
5. Microsoft's D3D12 samples (HelloTexture, nBodyGravity, MiniEngine).
6. vkd3d-proton's own D3D12 test suite, run in the guest through our driver.
7. 3DMark Time Spy, then real titles.

Constraints:

- This is the largest single piece of work in the project. UTM estimated 6–8
  months unassisted for the D3D11 equivalent and described heavy AI-assisted
  debugging across guest/host and user/kernel boundaries. Plan accordingly;
  it must not block M1–M6.
- It is a kernel-adjacent Windows driver package: it needs the Windows build
  VM (WP4.6) and the signing answer (D12) first.
- Licence-compatible with upstream (MIT, like Mesa/virglrenderer) so it can
  be contributed back.

## D3DMetal policy (optional backend)

D3DMetal is not part of the planned path. It stays available as an opt-in
because UTM measured it faster than DXMT and it already covers D3D12.
Apple's licence restricts D3DMetal to evaluating games for Apple platforms and
to non-commercial distribution. Therefore:

- Never bundle `D3DMetal.framework`. Never download it for the user.
- Provide a settings pane: "Use Apple Game Porting Toolkit graphics (D3DMetal)"
  with a file picker for a framework the user obtained from Apple, a version
  check, and a plain-language note about Apple's terms.
- Requires Rosetta. If Rosetta or the framework is missing, use the bundled
  backends (DXMT, vkd3d-proton/MoltenVK)
  silently and show which backend is active in the status UI.
- Backend choice is per-VM-launch (it changes the render-server architecture).

## Display path (host side)

UTM renders through SPICE/CocoaSpice. We do not (D4). We need:

1. Two scanouts (desktop and atlas) as GPU textures in our process.
2. Sub-rectangle presentation into many `CAMetalLayer`/`CALayer`s.
3. Damage, cursor and vblank information.

### `ui/seemless` QEMU display backend (patch)

S1 finding: QEMU's built-in `-display dbus` backend is compiled into our
build and already exports scanouts and takes input from another process.
**S3 evaluates `-display dbus` first**; write `ui/seemless` only if dbus
cannot meet the latency, IOSurface or multi-scanout needs on macOS.

Modelled on QEMU's existing `ui/cocoa.m` GL path and `ui/dbus-listener.c`
(which already implements "export scanout to another process").

- Listens on a unix socket. Per connection, a small binary protocol:

  | Direction | Message | Payload |
  |-----------|---------|---------|
  | Q→A | `ScanoutIOSurface` | scanout id, width, height, format, y-flip, IOSurface mach port (sent via `IOSurfaceCreateMachPort` over a bootstrap/XPC side channel, or `IOSurfaceID` if global lookup is acceptable; decide in S3) |
  | Q→A | `Damage` | scanout id, rect list, frame serial, host timestamp |
  | Q→A | `ScanoutDisabled` | scanout id |
  | Q→A | `Cursor` | visible, hotspot, RGBA bitmap, position (when guest-drawn) |
  | A→Q | `Key`, `PointerAbs`, `PointerRel`, `Button`, `Wheel` | QEMU input events with scanout id |
  | A→Q | `SetDisplaySize` | scanout id, width, height, scale (→ virtio-gpu EDID/resize) |
  | A→Q | `FrameAck` | serial (back-pressure) |

- In the GL/ANGLE path the scanout is a texture; blit (or ideally bind) to an
  IOSurface-backed texture. One GPU copy per frame is acceptable for v1;
  zero-copy via shared `MTLTexture` handles is an M7 optimisation (the Triton
  post notes `MTLSharedTextureHandle` + XPC is the fastest route).
- Before guest drivers load (firmware, WinPE, safe mode) the scanout is a
  pixman software surface: upload it to the same IOSurface so the app has one
  code path.

### App-side renderer

- `DisplayRenderer` owns a `MTLDevice` and wraps each scanout IOSurface as an
  `MTLTexture`.
- Desktop/game mode: one `CAMetalLayer`, blit with optional scaling filter.
- Seamless mode: each window view samples a sub-rect of the atlas texture
  (05). Present with `CAMetalLayer.presentsWithTransaction = false`,
  `displaySyncEnabled` on by default.
- HiDPI: the guest runs at the Mac display's pixel resolution with Windows
  scaling set by the agent to match the backing scale factor (200% on Retina),
  so there is no host-side scaling in the common case.
- HDR, VRR/ProMotion pacing: M7.

## Resolution and multi-monitor

- Scanout 0 follows the Mac display the desktop/game window is on.
- In seamless mode scanout 0 is still where Windows lays out windows. Its
  size is the union of Mac displays in pixels, capped at 8192×8192 (verify
  virtio-gpu/Triton limits in S5). One big virtual monitor in v1; true
  multi-monitor topology (per-display DPI) is a later enhancement.
- Resize requests go through `SetDisplaySize`; the agent confirms via
  `ChangeDisplaySettingsEx` if the driver does not auto-apply.

## Driver build, signing and delivery

- KMD/UMD are built on Windows with the WDK and a Mesa build (`osy/build-mesa`
  scripts). We cannot build them on macOS. Plan: a **Windows ARM64 build VM**
  run by our own runtime (dogfooding), scripted in `scripts/build-drivers/`.
  Until that exists (M4), consume UTM's pre-built signed driver releases.
- Signing (D12, spike S2): find out how UTM's released drivers are signed
  (attestation-signed vs test-signed). Kernel drivers on ARM64 need a
  Microsoft-trusted signature unless test-signing is on, and test-signing
  requires Secure Boot off. For our own builds, production release requires an
  EV certificate and Hardware Dev Center attestation signing. Budget for this.
- Drivers are injected offline during image build (03) and updated via the
  guest tools ISO using `pnputil /add-driver /install`.

## Our relationship with upstream

- Pin every repo by SHA in `scripts/versions.lock`. Bump deliberately, with
  the benchmark suite (08) as the gate.
- Keep our QEMU changes out of the virtio-gpu/Neptune code so rebases stay
  cheap.
- Bugs in Triton/Neptune/DXMT: reproduce with UTM itself first; if it
  reproduces there, report/fix upstream rather than forking behaviour.
- Check UTM's games database (`db.getutm.app`) for per-title status before
  investigating a game; our graphics compatibility should match UTM's for the
  same pinned versions.
- Licences of each component must be recorded before first binary release
  (10).

## Debugging aids to build early

- `seemlessctl gfx info`: active backend, render-server PIDs/architecture,
  capsets negotiated, driver versions reported by the agent.
- Env passthrough: `VIRGL_LOG_LEVEL`, DXMT, vkd3d-proton (`VKD3D_DEBUG`), MoltenVK (`MVK_CONFIG_*`) and D3DMetal debug variables.
- Frame capture: dump any scanout IOSurface to PNG (`seemlessctl screenshot
  --scanout N`). This is the primary verification tool for agents working on
  this project, since they cannot look at the screen directly.
- Guest-side: agent command to run `dxdiag /t` and return the file.
