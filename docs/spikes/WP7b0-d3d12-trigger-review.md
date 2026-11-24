# WP7b.0 — Guest D3D12 driver: trigger review

Status: **done** (2026-11-23). Verdict: **no-go for writing our own guest
D3D12 driver**. The trigger in docs/04 ("Guest D3D12 driver") has not fired.
Upstream already ships one, and our pinned host already has a vkd3d-proton
slot for it. M7b stays dormant; the D3D12 work moves to WP7.5 (host side
only).

Method: read upstream repositories with `gh` and `git ls-remote`, the
release notes of the driver S2 installed, the strings in its UMD, and the
Neptune host loader in our pinned virglrenderer (`build/src/virglrenderer`,
`dd0652b`). Nothing was run in a guest for this note.

## Trigger conditions (docs/04)

| Condition | Finding |
|-----------|---------|
| Upstream has no public D3D12 UMD that renders a triangle in a Windows guest | **False.** Triton, the Neptune UMD, implements the D3D12 DDI: `tritonDDI12.c`, `tritonList12.c`, `tritonPipeline12.c`, `tritonQueue12.c`, `tritonPresent12.c`, `tritonResource12.c`, `tritonDescriptor12.c` and `triton12.h` on `utmapp/mesa` `neptune`. That branch's head `68b837cd` is the same SHA we pin as `win-umd-mesa`. The released v0.6 package that S2 installed (`neptune_umd_arm64.dll`) exports `OpenAdapter12` and logs "Triton: OpenAdapter12: host caps=…". The open utmapp/mesa#7 (DXR) reports D3D12 tests passing on ARM64 and x64 guests and Counter-Strike 2 (D3D12) at ~100 fps, all on D3DMetal |
| Upstream's driver exists but is tied to D3DMetal-only behaviour that vkd3d-proton cannot satisfy | **False for the driver as a whole.** See below |

## The host already has a vkd3d-proton slot

From `src/neptune/npt_library.c` and `npt_library_names.h` (pinned `dd0652b`):

- **Separate library slot.** The D3D12 backend is its own dlopened library,
  set by `NPT_D3D12_LIBRARY_PATH`, separate from the D3D11/DXGI umbrella.
- **Defaults per platform:**

  | Platform | D3D12 backend |
  |----------|---------------|
  | Apple x86_64 | `libd3dmetal-native.dylib` |
  | Apple arm64 | `libdxmt-native.dylib`, which has no `D3D12CreateDevice`. That is the "symbol not found" S2 saw, and why D3D12 "degrades cleanly" today |
  | Elsewhere | `libvkd3d-proton-d3d12.so` |

- **Contract on macOS arm64.** `D3D12CreateDevice` is required. The
  root-signature serializers are optional. The calling convention is plain:
  `NPT_STDMETHODCALLTYPE` is `ms_abi` only on Apple x86_64. The
  directx-native ABI check (`vkd3d_native_abi_version`) is compiled out on
  `__APPLE__`. On macOS the darwin heap-import hook comes from the D3D11
  umbrella and is optional: without it, `CREATE_HEAP_FROM_SHMEM` fails
  cleanly and the guest uses its sync-copy path.
- **Workarounds.** Triton gates host-specific patches on per-backend
  workaround flags (`NPT_WA_*`), so it is built to run on more than one
  host D3D12.
- **Upstream's vkd3d-proton fork.** The Neptune author keeps one:
  `osy/vkd3d-proton` branch `neptune`, last commit `a8b7cd42` (2026-10-15),
  3 commits ahead and 40 behind `master`. It adds native dmabuf interop
  (texture export, heap import, the directx-native dmabuf contract) and a
  DXIL fix. That is the Linux embedder path.

So the plan in D3a is already the shape of upstream's own design:

- guest Triton (D3D12 DDI) → Neptune D3D12 protocol;
- host `npt` dispatch → `D3D12CreateDevice` from a vkd3d-proton library.

We supply the library: vkd3d-proton built natively for macOS arm64 on
KosmicKrisp or MoltenVK (S8).

## What stays D3DMetal-only (known so far)

- **Raytracing.** utmapp/mesa#7 is open, opt-in, and tuned to D3DMetal's
  acceleration-structure rules. S8 found no ray-tracing path on either
  Vulkan driver anyway.
- **Unproven on vkd3d-proton.** Nobody has published Triton running against
  vkd3d-proton on macOS. Zagrios/neptune (GPL-3.0; read only, nothing
  copied) runs the guest driver under Wine with a macOS render server, not
  vkd3d-proton.
- **Main risk: presentation.** On Apple arm64, DXGI and D3D11 come from
  DXMT, but the D3D12 device would come from vkd3d-proton. D3D12 swapchain
  present (`tritonPresent12.c`) and D3D11-on-12 / shared textures between
  the two backends are untested. docs/04 already expected this: both must
  end in `shm_open`-backed Metal memory.

## Consequences

- **D3b:** "write our own if necessary" is not necessary today. The
  trigger is checked again whenever upstream changes the D3D12 protocol in
  a way vkd3d-proton cannot follow.
- **M7b:** WP7b.1–WP7b.7 are not started. The bring-up ladder in docs/04
  still applies, run against upstream's driver instead of ours.
- **WP7.5** becomes the D3D12 critical path, host only:
  1. Build vkd3d-proton as a native macOS arm64 dylib exporting
     `D3D12CreateDevice` and the serializers. Start from S8's port
     (`spikes/S8-d3d12-moltenvk/vkd3d-proton-macos.patch`) rebased onto
     `osy/vkd3d-proton` `neptune`; pin both.
  2. Run it on **MoltenVK**, the owner's D3a choice (2026-11-23; S8 had
     recommended KosmicKrisp). Use S8's rung-1 patches: stream output
     optional and unaligned texel buffers in vkd3d-proton, plus
     `robustBufferAccess2` and `nullDescriptor` (H3/H4) in MoltenVK.
  3. Point `NPT_D3D12_LIBRARY_PATH` at it in the QEMU launch environment
     (`QEMUCommand`; `NPT_BACKEND` is set there already).
  4. Ladder rung 1 in the guest with the v0.6 driver: `D3D12CreateDevice`
     succeeds and dxdiag/a D3D12 test reports a feature level. Then
     clear/readback, triangle, present, samples, Time Spy.
  5. Darwin heap import (the `fd` twin) later, for performance.
- **WP4.6** (our own driver build VM) is no longer on the D3D12 critical
  path. It is still wanted to stop depending on UTM's prebuilt drivers.
- **Prerequisite for any guest test:** the virtio-gpu reset abort (S2; see
  docs/STATUS.md) must be fixed first.

## Contacting UTM's maintainers (not sent)

docs/04 asks us to tell UTM's maintainers our intent before starting. That
is an outward-facing post, so it is the owner's to send. Draft, for a GitHub
Discussion on utmapp/UTM or an issue on utmapp/virglrenderer:

> **Running Triton's D3D12 path on vkd3d-proton on macOS arm64**
>
> We're building a macOS host for Windows-on-Arm guests on top of Neptune
> (pinned: virglrenderer `dd0652b`, mesa `68b837cd`, viogpu-wddm v0.6).
> On Apple arm64 the D3D12 slot defaults to DXMT, which has no D3D12, so
> we'd like to fill `NPT_D3D12_LIBRARY_PATH` with vkd3d-proton built
> natively for macOS. We'd start from `osy/vkd3d-proton` `neptune`, on
> Mesa's KosmicKrisp or MoltenVK.
>
> Before we start, three questions:
> 1. Is this a direction you'd accept upstream? Is there existing or
>    planned work on it we should join rather than duplicate?
> 2. Do you expect D3D12 present and D3D11 interop to work with DXGI from
>    DXMT and the D3D12 device from a different library? Or should a single
>    umbrella provide all three?
> 3. Should the `vkd3d_` embedder ABI check and the dmabuf heap import be
>    enabled on darwin with an fd-based twin, as the D3D11 umbrella already
>    does?
>
> We'll send fixes upstream (MIT, matching virglrenderer/mesa).

## Sources

- [utmapp/mesa#7](https://github.com/utmapp/mesa/pull/7): triton12 DXR
  forwarding; D3D12 tests and CS2 on D3DMetal.
- [Introducing Neptune](https://blog.getutm.app/2026/introducing-neptune-direct3d-virtualization-for-qemu/),
  UTM blog.
- [viogpu-wddm v0.6 release](https://github.com/utmapp/viogpu-wddm/releases/tag/v0.6),
  the driver S2 installed.
- `utmapp/mesa` `neptune` tree, read with `gh api …/git/trees/neptune`.
- [osy/vkd3d-proton](https://github.com/osy/vkd3d-proton/tree/neptune),
  branch `neptune`.
- [Zagrios/neptune](https://github.com/Zagrios/neptune) (GPL-3.0; README
  only).
- [utmapp/UTM#7981](https://github.com/utmapp/UTM/issues/7981): a related
  reboot abort (hvf, fixed for reset by utmapp/qemu#6). It is not the S2
  `eglDestroyImageKHR` crash.
