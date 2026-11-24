# S8 spike tooling: vkd3d-proton on MoltenVK (host only)

Throwaway code for spike S8. Findings: `docs/spikes/S8-d3d12-moltenvk.md`.
Nothing here is product code. The patch is derived from vkd3d-proton
(LGPL-2.1); everything else in this folder is ours.

| File | What it is |
|------|------------|
| `deps.lock` | Exact versions of every source, submodule, Homebrew formula and pip package the spike uses |
| `check-deps.sh` | Compares the machine with `deps.lock`; `build.sh` runs it before building |
| `build.sh` | Fetch vkd3d-proton at the `scripts/versions.lock` SHA into `build/src/vkd3d-proton`, apply the patch, build into `build/s8/vkd3d-build` (macOS 26.0 target, tests on) |
| `vkd3d-proton-macos.patch` | Minimal native-macOS port (see below) plus the spike-only `S8_SOFT_CAPS` switch |
| `compat/sys/eventfd.h` | `eventfd` emulation (Unix datagram socket connected to itself). Spike only |
| `run-tests.py` | Runs the `d3d12` test binary one test per process (upstream's runner needs Linux) |
| `probe/vkprobe.c` | Prints the Vulkan features/limits/extensions vkd3d-proton checks, for any ICD |
| `compare.py` | vkd3d-proton's extension list vs one or more probe outputs → Markdown gap table |
| `demos/demo_headless.h` | Headless backend for upstream's `triangle`/`gears` demos (render targets + readback → PPM) |
| `demos/d3d12caps.c` | Prints the feature level, shader model and tiers vkd3d-proton reports |
| `build-demos.sh` | Builds the demos, `d3d12caps` and `vkprobe` into `build/s8/bin` |

## Reproduce

```bash
spikes/S8-d3d12-moltenvk/build.sh all
spikes/S8-d3d12-moltenvk/build-demos.sh
```

The Vulkan loader is Homebrew's, so every run needs
`DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`. Do not wrap the binaries in
`/usr/bin/timeout` or another system binary: SIP strips `DYLD_*` variables.

```bash
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib VKD3D_SHADER_CACHE_PATH=0
build/s8/bin/vkprobe                       # driver capabilities
S8_SOFT_CAPS=1 build/s8/bin/d3d12caps      # D3D12 caps vkd3d-proton reports
S8_SOFT_CAPS=1 S8_DEMO_OUT=/tmp/t.ppm build/s8/bin/triangle
python3 -I spikes/S8-d3d12-moltenvk/run-tests.py build/s8/vkd3d-build/tests/d3d12 \
    build/s8/out/moltenvk-soft --jobs 6 --env DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
    --env VKD3D_SHADER_CACHE_PATH=0 --env S8_SOFT_CAPS=1
```

Pick another Vulkan driver with `VK_DRIVER_FILES=<icd.json>`.

## What the patch changes

Port (needed on any macOS build):

- `meson.build`: accept `darwin` like Linux.
- `vkd3d_sonames.h`: upstream's Apple soname for d3d12core lacks the `lib`
  prefix, so `libvkd3d-proton-d3d12` never finds `libvkd3d-proton-d3d12core`.
- `platform.c`: `getprogname()` instead of `/proc/self/exe`.
- `vkd3d_threads.h`: macOS `pthread_setname_np`, `pthread_threadid_np`, and
  `pthread_cond_timedwait_relative_np` (no `pthread_condattr_setclock`).
- `file_utils.c`: `renamex_np(RENAME_EXCL)` for `renameat2(RENAME_NOREPLACE)`.
- `cache.c`: `ftello`/`fseeko` for the `*64` variants.
- `device.c`: enable `VK_KHR_portability_enumeration` (instance) and
  `VK_KHR_portability_subset` (device). Without them the loader hides
  MoltenVK and instance creation fails with `VK_ERROR_INCOMPATIBLE_DRIVER`.
- `cs_emit_nv_memory_decompression_regions.comp`: split a `uvec3` into
  three `uint`s. MoltenVK's SPIRV-Cross emits `&vec[0]` for an atomic on a
  vector component, which Metal rejects, and that pipeline is built at
  device creation.

Spike only:

- `device.c`: `S8_SOFT_CAPS=1` turns the hard requirement checks in
  `vkd3d_init_device_caps` into logged errors, so the device is created
  anyway and the test suite shows what breaks next. This makes vkd3d-proton
  promise features the driver does not have. Never ship it.
