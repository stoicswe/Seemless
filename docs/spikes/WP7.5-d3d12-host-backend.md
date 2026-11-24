# WP7.5 — D3D12 host backend (vkd3d-proton on MoltenVK)

Date: 2026-11-24 · Machine: Apple M3, macOS 27.3 · Status: **rungs 1–3 pass
in the guest with DXBC; DXIL in the guest is blocked by Triton's caps** (see
"Ladder").

The D3D12 library Neptune loads from `NPT_D3D12_LIBRARY_PATH` is now built by
us: upstream's Neptune fork of vkd3d-proton, native macOS arm64, running on a
patched MoltenVK built from source. D3D11/DXGI stay on DXMT.

```
guest D3D12 app → d3d12.dll → Triton UMD (OpenAdapter12) → Neptune
  → virgl_render_server → libvkd3d-proton-d3d12.dylib (+ d3d12core)
  → libMoltenVK.dylib (loaded directly, no Vulkan loader) → Metal
```

## Build

`scripts/build-deps.sh moltenvk vkd3d` (also part of `all`). Every source is
pinned in `scripts/versions.lock`; the owner approved the new downloads
(2026-11-24). Outputs in `build/prefix/lib`: `libMoltenVK.dylib`,
`libvkd3d-proton-d3d12.dylib`, `libvkd3d-proton-d3d12core.dylib` (arm64,
minos 26.0); headers in `build/prefix/include/vkd3d-proton`.

- **MoltenVK** v1.4.2 from source with its Xcode projects. `External/` is
  filled from our pinned checkouts (`mvk-*` in versions.lock), not by
  `fetchDependencies` (it would also clone the demo-only Volk and
  Vulkan-Tools) and not by the CMake build (CPM downloads itself).
- **vkd3d-proton** `osy/vkd3d-proton` `neptune` `a8b7cd4`. Its meson wrap
  `directx-native` is fetched by build-deps.sh (`7258be1`) and copied into
  `subprojects/`; meson runs with `--wrap-mode=nodownload`. Tests and demos
  are off: the test harness needs `eventfd`.
- **No Vulkan loader.** vkd3d-proton dlopens `@loader_path/libMoltenVK.dylib`
  (`VKD3D_VULKAN_LIBRARY=<dylib>` overrides, e.g. Homebrew's loader or
  KosmicKrisp). This replaces docs/04's "ICD selection by environment".

### Patches

| Patch | What |
|-------|------|
| `patches/vkd3d-proton-npt/0001-macos-native-port.patch` | S8's port rebased onto the fork, minus `S8_SOFT_CAPS`: meson darwin, sonames (`@loader_path`, upstream's missing `lib` prefix), pthread/rename/ftello, portability enumeration/subset, the MSL-safe decompression shader, header install on darwin, and the cooperative-matrix instance function made optional (MoltenVK used directly has no loader trampoline for it) |
| `patches/vkd3d-proton-npt/0002-darwin-directx-native-events.patch` | Event HANDLEs on macOS are directx-native events (below) |
| `patches/vkd3d-proton-npt/0003-moltenvk-h1-h2-requirements.patch` | S8 **H1**: transform feedback optional (SO pipelines and SO query heaps return `E_NOTIMPL`). **H2**: no 1-texel view alignment needed; typed views start at the driver's alignment (16 B on MoltenVK) and the remainder goes through vkd3d-proton's typed offset buffer |
| `patches/moltenvk/0001-robustness2-null-descriptor.patch` | S8 **H3**: report `robustBufferAccess2` on Apple GPUs. **H4**: report `nullDescriptor`; null buffer descriptors (argument buffers, CPU-side descriptors, vertex buffers) point at one zero-filled, resident 64 KiB buffer instead of address 0 |

Known deviations, accepted for rung 1 and listed for later work:

- H3 is reported, not implemented exactly: Apple GPUs bounds-check against
  the bound Metal buffer, not the descriptor range. Out-of-range reads inside
  a larger allocation return neighbouring data, not zero (S8's
  `test_buffers_oob_behavior_*`).
- H4: writes through a null UAV land in the shared zero buffer; a null vertex
  buffer reads (0,0,0,0) instead of (0,0,0,1). Null textures stay nil (read
  as zero on Apple GPUs; relied on, not separately tested).
- H2 covers heap descriptors only. Internal views made with
  `vkd3d_create_buffer_view` (typed UAV clears, some copies) can still be
  misaligned on MoltenVK.
- No stream output (H1).

### Events: why vkd3d-proton signals DXMT's events

On macOS Neptune creates every guest event through the D3D11 umbrella's
embedder API (`dxmt_event_create`, `npt_event.c`) and passes that handle to
whichever library completes the fence, including the D3D12 one. The handle is
a directx-native event (a pointer to user-space state), and
`dxn_event.h` says only the copy that created it may operate on it.
Patch 0002 signals and waits on it with vkd3d-proton's own static copy. That
is safe only because DXMT and the fork pin **the same directx-native
revision** (`7258be1`); `build_vkd3d` refuses to build when they differ.
If they ever diverge, the fix is an exported `dxmt_event_signal` (or a
per-backend event table in Neptune), not a layout guess.

The launcher also sets `VKD3D_SHADER_CACHE_PATH` to the VM's
`shader-cache/` folder (created on start): without it vkd3d-proton wrote
`vkd3d-proton.cache` into QEMU's working directory (the repo root during
these runs). Cache persistence policy stays WP7.9.

## Host harness

`scripts/d3d12-host/build.sh` builds `build/wp75/bin/d3d12hosttest`, which
loads the library as Neptune does (dlopen + dlsym, plain ABI) and runs rungs
1–3 on the host. It owns a separate copy of directx-native, as DXMT does in
QEMU, so rung 2's fence wait exercises patch 0002 across copies. Rung 3 is
`guest/tools/d3d12test/ladder_rung3.h`, shared with the guest test, so both
draw the same frame. Its DXIL shaders are signed containers taken at build
time from vkd3d-proton's `tests/d3d12_geometry_shader.c`
(`scripts/d3d12-host/extract-dxil.py`; LGPL test data, generated into
`build/`, never committed). It is a fixed host test, not a replay harness:
recording guest command streams for replay is not built.

```
$ VKD3D_SHADER_CACHE_PATH=0 build/wp75/bin/d3d12hosttest build/prefix/lib/libvkd3d-proton-d3d12.dylib
loaded build/prefix/lib/libvkd3d-proton-d3d12.dylib
rung1: D3D12CreateDevice(NULL, 11_0) hr 0, device 0x7516c04000
rung1: max feature level 11_0, highest shader model 6.0, resource binding tier 3, tiled resources tier 0, adapter LUID 00000000:00000000
rung2: clear 64x64 to (0.25,0.50,0.75,1.00), read back texel (0,0) = (64,128,191,255), 0 bad channels
rung3: triangle (DXBC VS+PS) covered 1152 px, centre (62,125,68,255), corner (0,0,0,255), fnv1a af00704d
rung3: triangle (DXIL VS+PS) covered 1152 px, centre (62,125,68,255), corner (0,0,0,255), fnv1a af00704d
device refcount after release: 0
PASSED (0 failures)
```

Rung 3 runs twice, with DXBC (SM 4/5) and with signed DXIL (SM 6) compiled
from the same HLSL; both frames are byte-identical. It covers exactly 1152 px,
the analytic area of the 48×48 px triangle.
The frame was dumped (`RUNG3_PPM=`) and looked at: red bottom-left, green
top, blue bottom-right, interpolated, black elsewhere.

Control: the same binary with `VKD3D_VULKAN_LIBRARY=/opt/homebrew/lib/libMoltenVK.dylib`
(unpatched MoltenVK 1.4.2) fails at `Robustness2 features not supported`
with `E_INVALIDARG`. So the device comes from the patches, with no capability
bypass.

## Guest

`guest/tools/d3d12test/` builds `d3d12guesttest.exe` on the Mac: a
freestanding Windows ARM64 console program (no CRT, no Microsoft SDK or
tools). Types come from vkd3d-proton's widl headers with `vkd3d_windows.h`
shadowed by an LLP64 copy (static asserts check the Windows layouts),
imports from our `.def` files via `llvm-dlltool`, linked by rustup's
`rust-lld -flavor link`. It runs rungs 1–3 against the guest's real
`d3d12.dll` and Triton, using Win32 events, and compares rung 3's hash with
the host reference. It reaches the guest on a small FAT32 disk
(`vm media attach … --as-disk`) and writes `result.txt` back to it.

VM `wp75` under `build/wp75/root`: fresh Lean image from the 26300 ISO with
`viogpu3d` v0.6 injected (`image build --drivers`, `FIRSTBOOT_OK` in 10 min
42 s); the owner accepted Microsoft's licence at first start. Snapshots
`clean-install` and `licence-accepted`. The test is started by typing into
the Run dialog over the VM's QMP input monitor (no agent yet). Output was
seen in the QEMU window (`screencapture -l`) and read back from the disk.

Run 3 (default capset `0xb7`, `VKD3D_DEBUG=warn`), `result.txt` as written
by the guest (Triton's own `neptune:` lines included):

```
Seemless d3d12guesttest (WP7.5)
adapter 0: Red Hat VirtIO GPU 3D controller vendor 0x1af4 device 0x1050 vram 8192 MiB
adapter 1: Microsoft Basic Render Driver vendor 0x1414 device 0x8c vram 0 MiB
neptune: virtgpu: KMD mode WDDM2 (GpuMmu)
neptune: virtgpu: kernel context virtual (native WDDM2 submit)
neptune: virtgpu: renderer ready (wire=0x00000002, caps=0x000000b7, max_timeline=64)
neptune: Neptune device created successfully
neptune: D3D12: host refuses a ROW_MAJOR texture on a CPU-visible heap (0x80070057)
rung1: D3D12CreateDevice(adapter, 11_0) hr 0x0
rung1: max feature level 12_0, highest shader model 5.1, resource binding tier 3, tiled resources tier 2
neptune: shared texture: export id 0x000000000000000b failed hr=0x80004001
neptune: shared texture: export id 0x000000000000000c failed hr=0x80004001
neptune: d3d12_heap: CREATE_HEAP_FROM_SHMEM(res=83 size=65536) failed 0x80004001
neptune: CreateHeap: shmem heap path failed; using host heap
rung2: fence event wait signalled, completed value 1
rung2: clear 64x64 to (0.25,0.50,0.75,1.00), read back texel (0,0) = (64,128,191,255), 0 bad channels
neptune: d3d12_heap: CREATE_HEAP_FROM_SHMEM(res=87 size=65536) failed 0x80004001
neptune: CreateHeap: shmem heap path failed; using host heap
neptune: shared texture: export id 0x000000000000001c failed hr=0x80004001
neptune: shared texture: export id 0x000000000000001d failed hr=0x80004001
neptune: d3d12_heap: CREATE_HEAP_FROM_SHMEM(res=88 size=65536) failed 0x80004001
neptune: CreateHeap: shmem heap path failed; using host heap
rung3: triangle (DXBC VS+PS) covered 1152 px, centre (62,125,68,255), corner (0,0,0,255), fnv1a 0xaf00704d = host reference
rung3: DXIL failed at CreateGraphicsPipelineState
FAIL: rung3 DXIL hr 0x80004005
FAILED (1 failures)
exit 1
```

What this shows:

- **The whole path works:** guest `d3d12.dll` → Triton → Neptune →
  vkd3d-proton → patched MoltenVK. The host log confirms
  `npt: loaded D3D12 library: …/build/prefix/lib/libvkd3d-proton-d3d12.dylib`.
- **Events across libraries work:** rung 2's Win32 event became a DXMT
  directx-native event that vkd3d-proton signalled (patch 0002).
- **Rung 3 with DXBC is byte-identical to the host reference.**
- **The guest sees different caps than the host device has.** Triton
  derives FL 12_0 and tiled resources tier 2 itself (from resource binding
  tier 3 and typed UAV loads), while vkd3d-proton reports FL 11_0 and tier 0.
  Apps choosing paths from those caps can hit features the host lacks.
- **DXIL is blocked in the guest by Triton, not by the host.** Triton
  advertises SM 6.x only when the capset has `CAP_DXIL`, which Neptune sets
  for D3DMetal and not for `NPT_BACKEND=dxmt`; so the runtime gets SM 5.1 and
  refuses the DXIL pipeline (`E_FAIL`). Forcing the bit
  (`NPT_CAPSET_CAPS=0xf7`, run 2) makes `D3D12CreateDevice` itself fail with
  `0x887A0020` (DXGI_ERROR_DRIVER_INTERNAL_ERROR). Reading `tritonDDI12.c`
  at our pin: with `CAP_DXIL` Triton also reports 3D pipeline level 12_1
  (it assumes D3DMetal), while the caps it forwards from vkd3d-proton have no
  conservative rasterization. The inconsistent report is the likely cause;
  not confirmed, since Triton's debug output was not captured in the guest.
  Fix options: a Triton change (DXIL independent of the 12_1 label; needs
  the driver build VM, WP4.6), or a host that reaches 12_1.
- **Not done yet:** shared-texture export and the shmem heap import fail
  with `E_NOTIMPL` (vkd3d-proton's native sharing is dmabuf-only). Triton
  falls back to host heaps, so off-screen work is fine; presentation and
  DWM sharing (rung 4) need the Metal-backed sharing from docs/04.
- The 3D-driver VM was shut down and restarted cleanly three times without
  the boot failure in STATUS (image with Fast Startup off, S6b).

## Reproduce

```bash
scripts/build-deps.sh moltenvk vkd3d
scripts/d3d12-host/build.sh
VKD3D_SHADER_CACHE_PATH=0 build/wp75/bin/d3d12hosttest build/prefix/lib/libvkd3d-proton-d3d12.dylib
guest/tools/d3d12test/build.sh          # build/wp75/guest/d3d12guesttest.exe
```

Guest: copy the exe and a `run.cmd` (runs it, writes `result.txt`) to a
FAT32 raw image, `seemlessctl vm media attach --name <vm> <img>` (attached
as a writable disk), start the VM (the launcher sets
`NPT_D3D12_LIBRARY_PATH`), run `run.cmd` in the guest, read `result.txt`
from the image after `vm stop`. `VKD3D_DEBUG=warn` in the environment of
`vm run` reaches vkd3d-proton (the QEMU log).

## Ladder (docs/04)

| Rung | Host | Guest |
|------|------|-------|
| 1 `D3D12CreateDevice`, feature level | ✅ FL 11_0, SM 6.0 | ✅ device created; runtime reports FL 12_0, SM 5.1 (Triton's caps, above) |
| 2 clear + readback | ✅ | ✅ exact, Win32 fence event signalled |
| 3 triangle vs host reference | ✅ DXBC and DXIL, reference `af00704d` | ✅ DXBC = `af00704d`; ❌ DXIL refused (SM 5.1 caps) |
| 4 swapchain present through DXGI/DWM | not tried | not tried: shared textures fail (`E_NOTIMPL`) |
| 5–7 samples, vkd3d-proton suite, Time Spy | not tried | not tried |

No performance claims: nothing here was measured with `seemlessctl bench`.
