# S1 — Build the host stack from pinned sources

Date: 2026-11-23 · Machine: Apple M3, macOS 27.3, Xcode 27.3 beta (Swift 6.4.2, clang 21)
Result: **Pass.** Every component builds from the SHAs in `scripts/versions.lock`
into `build/prefix`, arm64, targeting macOS 26.0. The full chain takes about
10 minutes wall-clock once sources are fetched (ANGLE and QEMU dominate).

## How to reproduce

```bash
scripts/build-deps.sh fetch      # ~1 min; QEMU with submodules is 2 GB
scripts/build-deps.sh all        # angle epoxy dxmt virgl libtpms swtpm qemu
scripts/smoke-qemu.sh            # headless: HVF VM + firmware + swtpm + QMP
scripts/smoke-qemu.sh --window   # GL device with venus+neptune on ANGLE/Metal (opens a window ~8 s)
```

Logs for every step: `build/logs/<step>.log`. Finished components are stamped
in `build/stamps/` (rebuild one with `--force <name>`).

## Acceptance (from docs/09)

| Check | Result |
|-------|--------|
| `qemu-system-aarch64 --version` | `QEMU emulator version 10.0.12` (utmapp/qemu `utm-edition` @ `8ab298bc`) |
| `-device help` lists `virtio-ramfb-gl` | Yes; it exposes `neptune`, `venus`, `blob`, `hostmem`, `max_hostmem`, `max_outputs` |
| Configure summary | HVF YES, Cocoa YES, virglrenderer YES 1.3.0 (`VIRGL_RENDERER_NEPTUNE` present), epoxy 1.5.11 with EGL, slirp 4.9.7 |
| Firmware installed | `share/qemu/edk2-aarch64-code.fd` (+ `-secure-code.fd`) |
| Every binary arm64, minos 26.0 | Yes for QEMU, virglrenderer + render server, DXMT, libepoxy, swtpm, libtpms. ANGLE is minos 12.0 by necessity (see deviations); runs on 26+ |
| Boot smoke test (headless) | VM runs under HVF with `ipa-granule-size=0x1000`; swtpm attached as `tpm-tis` TPM 2.0; edk2 reaches network boot (no disk) |
| Boot smoke test (`--window`) | Same, with `virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2` and `-display cocoa,gl=es`; no errors |

### What the smoke test does **not** prove

QEMU initialises virglrenderer lazily, on the first control command from a
guest driver (`hw/display/virtio-gpu-gl.c`, `RS_START` → `virtio_gpu_virgl_init`).
Firmware never sends one. So virglrenderer, the render-server processes,
Venus/MoltenVK and Neptune/DXMT have **not been exercised at runtime**. That
is S2's job (Windows + Triton drivers). Nothing was visually checked either:
the windowed run was verified only through QMP and stderr.

## Deviations from UTM's Triton build notes

| # | Component | Deviation | Why |
|---|-----------|-----------|-----|
| 1 | ANGLE | `MACOSX_DEPLOYMENT_TARGET=12.0` instead of 11.0 | Xcode 27 rejects deployment targets below 12.0 |
| 2 | ANGLE | Not 14.0 or 26.0 either | WebKit's `Configurations/CommonBase.xcconfig` adds `-D_LIBCPP_ENABLE_ASSERTIONS=1` for macOS ≥ 14, and the macOS 27 SDK's libc++ hard-errors on that macro (it was replaced by `_LIBCPP_HARDENING_MODE`). Overriding `WK_LIBCPP_ASSERTIONS_CFLAGS*` would allow 26.0 later |
| 3 | ANGLE | `GCC_TREAT_WARNINGS_AS_ERRORS=NO` | clang 21 reports `-Wshift-count-overflow` in `src/common/bitset_utils.h:726`, inside a branch that is dead for 64-bit bitsets. Warning only; no source patch |
| 4 | All others | `MACOSX_DEPLOYMENT_TARGET=26.0` exported for every build | Without it clang targets the build SDK (27.3) and binaries would not run on macOS 26 (D10) |
| 5 | virglrenderer | Native arm64 build only; no x86_64 render server, no `lipo` | The x86_64 slice exists only for the optional D3DMetal backend. The Neptune backend is `dlopen`ed by name at runtime and chosen by `NPT_BACKEND`, so there is no build-time dependency on DXMT or D3DMetal |
| 6 | virglrenderer | Needs Python `yaml` (gallium codegen) | Not mentioned by UTM. `build-deps.sh` creates `build/venv` with `pyyaml==6.0.3` (Homebrew has no PyYAML formula) |
| 7 | MoltenVK | Homebrew `molten-vk` 1.4.2, not built from source | Same version as the pin; docs/02 allows Homebrew for M0. Build from source before M8 |
| 8 | libepoxy | `-Dtests=false` | Not needed |
| 9 | QEMU | Also uses Homebrew glib, pixman, libslirp, zstd, libusb, gnutls | docs/02 allows Homebrew in M0; bundle in M8 |

Homebrew packages installed for this spike: `llvm@15` (keg-only, DXMT needs
exactly LLVM 15), `libslirp`, `json-glib`, `libtool`, `automake`, `gawk`,
`socat`. Already present: glib, pixman, zstd, libusb, gnutls, openssl@3,
libtasn1, vulkan-headers/loader, molten-vk, meson, ninja, cmake, pkg-config.

## Findings that change other docs

1. **QEMU's built-in `-display dbus` backend is compiled in.** It already
   exports scanouts and accepts input from another process (that is what
   `ui/dbus-listener.c` is for). Spike S3 should evaluate it first, before
   writing a custom `ui/seemless` backend (docs/04, D4). Its cost is a D-Bus
   session bus on macOS, which is unusual; measure latency both ways.
2. **TCG is compiled in.** For release, configure with `--disable-tcg` (HVF
   only) to avoid needing the `allow-jit` entitlement (docs/10 Distribution).
   Confirm firmware and Windows boot with HVF only.
3. **`max_outputs=2` is accepted** by `virtio-ramfb-gl` (inherited from
   virtio-gpu-base, limit 16). Whether the Windows driver drives a second
   display remains S5 (Q3).
4. **aarch64 firmware vars:** QEMU ships no aarch64 variable-store template
   (`edk2-arm-vars.fd` is 32-bit ARM and too small). Create a zeroed 64 MiB
   `efi_vars.fd` per VM (docs/02 storage layout).
5. **Licences read from source** (also in `THIRD_PARTY.md`): DXMT is
   **LGPL-2.1-or-later** (not zlib-style as first assumed); virglrenderer and
   libepoxy MIT; swtpm BSD-3; libtpms IBM BSD-style (TPM 2.0 code terms still
   to read).
6. **`virgl_render_server` links only libSystem**; it loads its backends at
   runtime. The library search path (`DYLD_FALLBACK_LIBRARY_PATH`) therefore
   matters at runtime, and bundling (M8) must put `libdxmt-native.dylib` where
   the render server's `dlopen` finds it.

## Open after S1

- Runtime exercise of virglrenderer/Venus/Neptune → S2.
- Pins are confirmed to *build*; they become confirmed-to-*work* after S2.
