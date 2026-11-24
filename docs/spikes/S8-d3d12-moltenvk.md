# S8 — D3D12 on MoltenVK / KosmicKrisp (vkd3d-proton, host only)

Date: 2026-11-23 · Machine: Apple M3, macOS 27.3 · No VM involved.
Versions: vkd3d-proton v3.1 @ `4522cc1a` (the `scripts/versions.lock` pin),
MoltenVK 1.4.2 (Homebrew, same as the pin; reports Vulkan 1.4.357,
conformance 1.4.4.0), KosmicKrisp from Mesa 26.3.1 @ `fec8830e` (built locally;
reports Vulkan 1.4.363, conformance 1.4.6.2), Homebrew vulkan-loader 1.4.363.

Result: **patch** (vkd3d-proton plus Vulkan-driver work; details under
"Recommendation"). vkd3d-proton
builds and runs natively on macOS arm64 with a small port patch. Unpatched
MoltenVK cannot create a D3D12 device: four of vkd3d-proton's hard Vulkan
requirements are missing. Bypass those checks and about 80% of the test
suite passes and the D3D12 demos render correctly, but the device only
reaches **feature level 11_0 / shader model 6.0**. Most D3D12 games need
12_0 and SM 6.x.

KosmicKrisp does clearly better: 2 of the 4 hard gaps instead of 4, about
88% of the suite passing with the checks bypassed (MoltenVK: 80%), one
device-loss test instead of 13, and FL 11_1. It still needs vkd3d-proton
patches for a device, and it is still far from 12_0 / SM 6.x. So the
verdict for the D3D12 path is **patch**, and KosmicKrisp is the better base
to patch (see "Recommendation").

## How to reproduce

All tooling is in `spikes/S8-d3d12-moltenvk/` (README there):

```bash
spikes/S8-d3d12-moltenvk/check-deps.sh     # machine matches deps.lock?
spikes/S8-d3d12-moltenvk/build.sh all       # fetch pin, patch, build (≈3 min)
spikes/S8-d3d12-moltenvk/build-demos.sh     # triangle, gears, d3d12caps, vkprobe
```

Every source SHA (including vkd3d-proton's submodules), Homebrew formula and
pip package the spike uses is pinned in `spikes/S8-d3d12-moltenvk/deps.lock`.
`build.sh` refuses to build when the machine differs (`S8_UNLOCKED=1`
overrides).

Outputs land in `build/s8/` (gitignored): `vkd3d-build/`, `bin/`, and
`out/` (probe dumps, per-test logs, `results.tsv`, demo frames).

## 1. Native build

vkd3d-proton has a native (non-Wine) Linux build: `libvkd3d-proton-d3d12`
plus `libvkd3d-proton-d3d12core`, loading `libvulkan` with `dlopen`. With
meson treating `darwin` like Linux it builds as arm64 dylibs (minos 26.0).
The port needs eight small changes (listed in the spike README):

- `pthread`, `/proc`, `renameat2`, `ftello64` differences.
- An upstream bug: the Apple soname for d3d12core lacks the `lib` prefix,
  so the two dylibs never find each other.
- `VK_KHR_portability_enumeration`/`_subset` must be enabled, or the loader
  hides MoltenVK (`VK_ERROR_INCOMPATIBLE_DRIVER`).
- One internal compute shader (DirectStorage GPU-decompression emulation,
  built at device creation) does `atomicAdd` on a `uvec3` component.
  MoltenVK's SPIRV-Cross turns that into MSL that Metal rejects
  (`address of vector element requested`), which fails device creation.
  Fixed in the shader by splitting the vector; also worth reporting to
  SPIRV-Cross.
- `eventfd` has no macOS equivalent. The spike emulates it with a Unix
  datagram socket connected to itself (`compat/sys/eventfd.h`; a UDP loopback
  version delivered asynchronously and broke the fence tests). Product code (WP7.5) must use
  kqueue or `MTLSharedEvent` and fd-free waits.

No Wine, no Windows headers and no Microsoft tools are involved (`widl`
comes from Homebrew `mingw-w64`). `D3DMetal.framework` was not used.

## 2. Test suite and demos

The test binary `tests/d3d12` holds 590 tests; 578 after removing the
stress tests, as upstream's runner does. `run-tests.py` runs each test in
its own process (90 s timeout, 6 in parallel).

A test **passes** when it exits 0 with zero failed checks. Many passing
tests skip sub-cases for features the device does not report (mesh shaders,
DXR, SM 6.6+, tiled resources and so on). Those count as passes, as they do
upstream.

| Run | Pass | Fail | Crash | Skip (no device) | Checks run / failed |
|-----|-----:|-----:|------:|-----------------:|--------------------:|
| MoltenVK, unmodified requirements | 22 | 3 | 0 | 553 | 2,439 / 51 |
| MoltenVK, `S8_SOFT_CAPS=1` (hard checks bypassed) | 461 | 89 | 28 | 0 | 26,504,912 / 112,252 |
| KosmicKrisp, unmodified requirements | 22 | 3 | 0 | 553 | 2,439 / 51 |
| KosmicKrisp, `S8_SOFT_CAPS=1` | 510 | 49 | 18 (+1 timeout) | 0 | 26,505,374 / 79,112 |

In the bypassed run, 159 of the 461 passing tests skipped some sub-cases.
Five of the 28 crashes change from run to run: MoltenVK sometimes aborts with
"mutex lock failed: Invalid argument" (an uncaught C++ exception inside the
driver) in whichever test happens to hit it (C13). An earlier identical run
had 464 / 91 / 23.

The 22 strict passes need no device (root-signature serialisation and the
like). The 3 strict failures are the device-factory tests failing to create a
device (`E_INVALIDARG`).

Demos (upstream `triangle` and `gears`, with a headless backend: render
targets read back to PPM; vkd3d-proton's own DXGI/Vulkan swapchain is **not**
exercised):

| Demo | Unmodified | `S8_SOFT_CAPS=1` |
|------|-----------|------------------|
| triangle (640×480, 120 frames) | `D3D12CreateDevice` fails | Renders correctly (checked by reading the frame back as an image) |
| gears (300×300, 120 frames, animated, depth buffer, instancing) | `D3D12CreateDevice` fails | Renders correctly (same check) |

D3D12 caps vkd3d-proton reports on MoltenVK with `S8_SOFT_CAPS=1`
(`d3d12caps`): max feature level **11_0**, highest shader model **6.0**,
resource binding tier 3, tiled resources tier 0, conservative raster tier 0,
ROVs yes, logic op no, typed UAV loads yes, FP64 no, wave ops yes,
Int64 yes, ray tracing / VRS / mesh / sampler feedback none.

## 3. Gap list: what vkd3d-proton needs that MoltenVK 1.4.2 lacks

From `vkprobe` (MoltenVK's own report) checked against vkd3d-proton's
`libs/vkd3d/device.c`, plus the failure logs. Raw data:
`build/s8/out/probe-moltenvk.txt` and `build/s8/out/moltenvk-*/`.

### 3a. Hard requirements (no device without them)

| # | vkd3d-proton check | MoltenVK 1.4.2 | Fix options |
|---|--------------------|----------------|-------------|
| H1 | `VK_EXT_transform_feedback` with `transformFeedbackQueries` | Extension absent. Metal has no stream output | Make SO optional in vkd3d-proton (games rarely use it; D3D12 requires it on paper), or emulate it in MoltenVK the way it already emulates tessellation with compute |
| H2 | Texel-buffer offsets aligned to one texel (`{storage,uniform}TexelBufferOffsetSingleTexelAlignment` or 1-byte alignment) | 16-byte alignment | Patch vkd3d-proton to emulate unaligned typed views (offset folded into the shader), or MoltenVK to back texel buffers differently |
| H3 | `VK_EXT_robustness2` `robustBufferAccess2` | 0 (`robustImageAccess2` = 1) | MoltenVK/SPIRV-Cross: exact-size bounds checks; MoltenVK already passes buffer sizes for `robustBufferAccess` |
| H4 | `VK_EXT_robustness2` `nullDescriptor` | 0 | MoltenVK: bind dummy resources for null descriptors in argument buffers |

Already satisfied: vertex attribute divisor (incl. zero divisor),
`samplerMirrorClampToEdge`, `shaderDrawParameters`, push descriptors,
maintenance5/6, Vulkan 1.3+, timeline semaphores, BDA, dynamic rendering,
descriptor indexing with update-after-bind (limits around 10^6).

### 3b. Needed for correct D3D12 11_0 behaviour (device works, results wrong or GPU fault)

| # | Missing in MoltenVK | Effect seen in the suite |
|---|---------------------|--------------------------|
| C1 | `VK_EXT_dynamic_rendering_unused_attachments` (vkd3d-proton warns: "required for correct operation") | Device loss in `test_unused_attachments_mix_and_match`, `test_rendering_no_attachments_layers`, `test_null_rtv`, `test_draw_uav_only` |
| C2 | Geometry shaders (`geometryShader` = 0; Metal has none) | `test_geometry_shader_*`, `test_gs_topology_mismatch_*`, layered rendering via GS fail. D3D12 requires GS at every feature level |
| C3 | `VK_EXT_custom_border_color` | Border-colour tests fail (8,192 failed checks each); D3D12 allows arbitrary border colours |
| C4 | `VK_EXT_depth_clip_enable` | `DepthClipEnable = FALSE` cannot be honoured |
| C5 | `VK_EXT_conditional_rendering` | Predication (`SetPredication`) unsupported |
| C6 | `shaderCullDistance` = 0 | Clip/cull distance tests fail or crash |
| C7 | Pipeline statistics queries (`pipelineStatisticsQuery` = 0) | `VK_ERROR_FEATURE_NOT_PRESENT` creating the query heap, then the test crashes |
| C8 | Tessellation: SPIRV-Cross rejects `Component` decorations in tessellation shaders | Tessellation pipelines fail to build (`test_*_tessellation_*`) |
| C9 | SV_Barycentrics: SPIRV-Cross cannot emit both perspective and no-perspective barycentrics in one shader | `test_sv_barycentric` |
| C10 | Typed buffers limited to 64 Mi elements (`maxTexelBufferElements`; Metal 256 Mi texture width) | `test_large_texel_buffer_view` hits a Metal validation abort |
| C11 | Device loss under ROVs, atomics and some UAV patterns (`test_rasterizer_ordered_views_*`, `test_atomic_instructions_*`, `test_derivative_hoisting_*`, `test_dynamic_index_strip_cut`, `test_map_placed_resources`, `test_resolve_image_exhaustive_descriptors`) | MoltenVK reports ROV support (`fragmentShaderPixelInterlock` = 1) but ordering tests fail before the device is lost. Cause not isolated in this spike |
| C13 | Intermittent abort inside MoltenVK: `std::system_error: mutex lock failed` | Random tests crash (5 of 28 crashes in the final run); not reproducible on demand |
| C12 | Format reinterpretation (`test_tex*/rwtex*_array_reinterpretation_*`, `test_rgb9e5_rendering`), `test_view_min_lod`, `test_sample_instructions`, primitive restart with list topology, triangle fans, timestamp queries going backwards | Wrong results; mostly MoltenVK view/format and Metal topology limits |

The robustness failures (`test_buffers_oob_behavior_*`,
`test_null_descriptor_*`, `test_uav_robustness_*`, `test_*_addressing_wrap`,
`test_undefined_*`) are H3/H4 showing up at runtime. They pass only because
`S8_SOFT_CAPS` let the device be created.

### 3c. Missing for feature level 12_0+ and shader model 6.x

vkd3d-proton derives the feature level and shader model from these. All of
them are missing on MoltenVK 1.4.2:

| Target | Missing | Notes |
|--------|---------|-------|
| FL 11_1 | `logicOp` (Metal has no logic ops); `maxPerStageDescriptorStorageBuffers` ≥ 64 (MoltenVK reports 31) | The buffer limit is the non-argument-buffer Metal slot count. vkd3d-proton binds bindlessly, so this gate could be relaxed |
| FL 12_0 | Tiled resources tier 2 (`sparseBinding`, `sparseResidencyBuffer/Image2D` all 0) | Apple GPUs have Metal sparse textures and placement heaps; MoltenVK does not implement Vulkan sparse |
| FL 12_1 | `VK_EXT_conservative_rasterization` | Metal has no conservative rasterization |
| FL 12_2 | DXR (`VK_KHR_ray_tracing_pipeline`, `_acceleration_structure`, `_ray_query`), `VK_KHR_fragment_shading_rate`, `VK_EXT_mesh_shader`, depth bounds | Metal has ray tracing, mesh shaders and rasterization-rate maps, but MoltenVK exposes none of them |
| SM 6.2 (and so 6.3–6.5) | Denormal controls (`denormBehaviorIndependence` = NONE, no FTZ/preserve for FP32) | Without this vkd3d-proton stops at SM 6.0. Many DX12 games need SM 6.x |
| SM 6.6 | `shaderBufferInt64Atomics`, `VK_KHR_compute_shader_derivatives` | UE5 (Nanite) needs SM 6.6. Metal has only 64-bit min/max atomics |
| SM 6.7 | `VK_KHR_shader_quad_control` | `shaderMaximalReconvergence` is present |
| Fast paths | `VK_EXT_mutable_descriptor_type`, `VK_EXT_descriptor_buffer`, `VK_EXT_graphics_pipeline_library`, `VK_EXT_device_generated_commands`, `VK_EXT_image_view_min_lod`, `VK_EXT_memory_priority`/`pageable_device_local_memory`, `VK_EXT_depth_bias_control` | Not required, but without them vkd3d-proton uses slower descriptor copies, has more PSO compile stutter, and emulates ExecuteIndirect |
| Also | `shaderFloat64` = 0, `samplerFilterMinmax` = 0, `variableMultisampleRate` = 0, `VK_EXT_shader_image_atomic_int64` | FP64 shader ops off; min/max filtering (tiled-resource tier 2 feature) off |

Full list of the 50 non-vendor extensions vkd3d-proton knows about and
MoltenVK lacks: run `compare.py` (spike README). Many of them are
optional or very new.

vkd3d-proton also has `VKD3D_FEATURE_LEVEL` and `VKD3D_SHADER_MODEL`
overrides (Proton uses them per game). They make the device *claim* more
than the driver has; they do not supply the missing features.

## KosmicKrisp

Built locally with `spikes/S8-d3d12-moltenvk/build-kosmickrisp.sh` (Mesa
`-Dvulkan-drivers=kosmickrisp -Dplatforms=macos` only). Its internal kernels
need Mesa's OpenCL compiler, so SPIRV-Headers `cb42dec3`,
SPIRV-LLVM-Translator v23.1.3 and libclc (llvmorg-23.1.5) were built into
`build/s8/clc-prefix` against Homebrew LLVM 23.1.5. Each was approved by the
owner and is pinned in `deps.lock`; nothing was installed system-wide.

Build pitfalls, all handled in the script:
- libclc's SPIR-V targets need Homebrew clang (Apple clang has no SPIR-V
  target).
- Apple `ar`/`ranlib` silently produce empty archives from bitcode, so use
  `llvm-ar`/`llvm-ranlib`.
- LLVM 23 libclc ships no `libclc.pc` and uses new file names, so the script
  writes one and stages the files under Mesa's names.
- Static LLVM needs `-L/opt/homebrew/lib` for zstd.
- Without `-Dplatforms=macos` KosmicKrisp has no `VK_KHR_surface`, which
  vkd3d-proton requires at instance creation.

Runtime: the driver loads Homebrew `spirv-tools` and `zstd`, whose bottles
target macOS 27. A shipped build must build those for 26.0 (D10). KosmicKrisp
is not a portability driver, so it needs no portability opt-in.

| | MoltenVK 1.4.2 | KosmicKrisp (Mesa 26.3.1) |
|---|---|---|
| H1 transform feedback | missing | missing |
| H2 1-texel buffer alignment | missing (16 B) | missing (16 B) |
| H3/H4 `robustBufferAccess2`, `nullDescriptor` | missing | **present** |
| D3D12 device, unmodified | none | none |
| `S8_SOFT_CAPS=1` caps | FL 11_0, SM 6.0 | **FL 11_1**, SM 6.0 |
| Logic op, depth clip, conditional rendering, mutable descriptors | missing | **present** |
| Storage buffers per stage | 31 | 1,048,576 |
| `maxTexelBufferElements` | 64 Mi | 256 Mi |
| ROVs (`fragmentShaderInterlock`), SV_Barycentrics, `VK_EXT_metal_objects` | present | missing |
| Metal memory import (`VK_EXT_external_memory_metal`) | present | present |
| Geometry shaders, sparse, custom border colours, unused attachments, denorm controls, int64 buffer atomics, compute derivatives, quad control, FP64, pipeline-statistics queries | missing | missing |
| Tests passing (`S8_SOFT_CAPS=1`) | 461 / 578 | **510 / 578** |
| Tests with device loss | 13 | **1** (`test_resolve_image_exhaustive_descriptors`) |
| triangle / gears demos (`S8_SOFT_CAPS=1`) | render correctly | render correctly (checked by reading the frames back as images) |

Test-by-test, MoltenVK → KosmicKrisp: 460 pass on both, 50 improve (36 fail→pass,
14 crash→pass), 7 get worse (6 fail→crash, 1 pass→timeout in
`test_dstorage_decompression`), 61 fail or crash on both. KosmicKrisp's
remaining failures are mostly the shared gaps:
- No stream output: the tessellation tests read results back through SO and crash.
- No geometry shaders: GS, layered and PS-layer tests.
- Custom border colours.
- Texel alignment and typed-buffer aliasing (`test_undefined_*`, `test_suballocate_*`).
- Format reinterpretation.
- Unused attachments.

The intermittent MoltenVK mutex abort (C13) does not occur.
Data: `build/s8/out/kk-*/`, `probe-kosmickrisp.txt`, `ext-gap.md`.

Mesa is MIT-licensed. It is not bundled, so `THIRD_PARTY.md` is unchanged
until we ship it.

## Recommendation: patch, not go and not no-go; prefer KosmicKrisp as the base

- **Not go.** Neither driver gives a D3D12 device without changes, and with
  the hard checks bypassed both stop at FL 11_x / SM 6.0. Most D3D12 games
  need 12_0 and SM 6.x.
- **Not no-go.** The translation works on Apple silicon. vkd3d-proton ports
  with a small patch, the device comes up, 80–88% of the suite and both
  demos are correct, and every gap is specific and listed. Most gaps are
  driver features Metal can back, not Metal limits.
- **KosmicKrisp is the better base.** It already has H3/H4 and much of
  C3–C5, has far fewer GPU faults, and sits in Mesa: NIR compiler, MIT
  licence, an active upstream that shares code with Mesa's other Vulkan
  drivers (for example the geometry-shader and transform-feedback emulation
  other Mesa drivers use). Costs: it is new and labelled experimental, it
  needs the LLVM/libclc toolchain at build time, it lacks ROVs and
  `VK_EXT_metal_objects`, and its Homebrew runtime dylibs must be rebuilt
  for macOS 26.
- **Patch plan**, in order:
  1. *Get a device (both drivers):* in vkd3d-proton (ours, small), make
     stream output optional (H1) and emulate unaligned typed buffer views
     (H2). On KosmicKrisp that is enough. MoltenVK also needs
     `robustBufferAccess2` and `nullDescriptor` (H3/H4, medium).
  2. *Correct FL 11_x:* geometry shaders and transform feedback emulation,
     custom border colours, unused attachments, cull distance, pipeline
     statistics, format reinterpretation. Work in Mesa, ideally reusing
     Mesa's existing emulation; for MoltenVK all of it plus SPIRV-Cross fixes
     and the device-loss causes (C11, C13).
  3. *FL 12_0 / SM 6.x:* sparse residency (large; Metal has sparse
     textures), denorm reporting for SM 6.2+ (likely a capability-reporting
     decision, since Apple GPUs flush FP32 denormals; compare with
     D3DMetal's behaviour), int64 buffer atomics and compute derivatives for
     SM 6.6 (int64 add needs emulation on Metal).
- Rough size: rung 1 is weeks; rungs 2–3 are months of driver work, most of
  it upstreamable.
- **Decision for the owner (D3a):** keep "vkd3d-proton on Vulkan on Metal",
  but choose the driver.
  - *Recommended:* KosmicKrisp is the D3D12 driver; we patch vkd3d-proton
    and contribute to Mesa. MoltenVK stays for Venus until KosmicKrisp covers
    that too (the driver is already swappable by ICD, docs/04).
  - *Alternative:* MoltenVK for both, accepting the larger gap list (3a–3c)
    and the GPU faults.

  Either way, add the chosen driver as a pinned `vendor/` source when WP7.5
  starts. If neither is funded, D3DMetal-only D3D12 remains the fallback in
  04.

## What this spike did not cover

- vkd3d-proton's swapchain (`IDXGIVkSwapChain`) on a `CAMetalLayer`. The
  demos used offscreen render targets. Neptune will present through shared
  textures anyway (WP7.5), not a Vulkan swapchain.
- Shared textures/fences (`VK_EXT_metal_objects`, `shm_open`-backed
  `MTLBuffer`s). WP7.5.
- Performance. No `seemlessctl bench` numbers exist for this path.
- Real games or Microsoft's D3D12 samples (no Windows binaries were run).
- Root-causing the device-loss tests (C11) and the MoltenVK mutex abort (C13).
- KosmicKrisp failures were grouped by cause but not root-caused one by one.
- Visual check: the demo frames were read back and inspected as images by
  the agent, not shown on a display.
