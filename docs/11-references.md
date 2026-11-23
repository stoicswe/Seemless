# 11 — References and verified facts

## How to read this file

"Verified" means read from the linked source on **2026-11-23**. Everything
else in the plan that is not listed here is design intent or background
knowledge and should be re-checked by the work package that depends on it.
Upstream moves fast: re-verify before relying on a fact older than a few
months.

## Primary sources

| Topic | Link |
|-------|------|
| QEMU upstream | https://github.com/qemu/qemu |
| UTM app | https://github.com/utmapp/UTM |
| UTM architecture doc | https://github.com/utmapp/UTM/blob/main/Documentation/Architecture.md |
| UTM docs: Windows guests / DirectX | https://docs.getutm.app/guest-support/windows/ |
| UTM docs: v5.0 notes | https://docs.getutm.app/updates/v5.0/ |
| UTM blog: Neptune (D3D over virtio-gpu) | https://blog.getutm.app — "Introducing Neptune: Direct3D virtualization for QEMU" (2026-05-16) |
| UTM blog: Triton (Windows D3D11 driver), incl. full build and run instructions | https://blog.getutm.app — "Introducing Triton: DirectX 11 driver for QEMU" (2026-07-24) |
| UTM blog: Triton bring-up notes | https://blog.getutm.app — "Bringup notes: building Triton" (2026-07-24) |
| UTM games database | https://db.getutm.app (has `.json` twins and `/llms.txt`) |
| QEMU fork (Neptune) | https://github.com/utmapp/qemu (`utm-edition`) |
| virglrenderer fork | https://github.com/utmapp/virglrenderer (`macos-next`) |
| DXMT fork (native macOS build) | https://github.com/utmapp/dxmt |
| d3dmetal-native | https://github.com/utmapp/d3dmetal-native |
| MoltenVK | https://github.com/KhronosGroup/MoltenVK |
| vkd3d-proton | https://github.com/HansKristian-Work/vkd3d-proton |
| Windows KMD | https://github.com/osy/kvm-guest-drivers-windows (`neptune`), `viogpu/viogpu3d/BUILDING.md`, prebuilt signed releases |
| Windows UMD (Mesa) | https://github.com/osy/virtio-win-mesa (`neptune`) |
| Driver build scripts | https://github.com/osy/build-mesa |
| Neptune protocol codegen | https://github.com/osy/neptune-protocol |
| Community Venus-for-Windows KMD work | https://github.com/anonymix007/kvm-guest-drivers-windows-venus, https://github.com/arehnman/kvm-guest-drivers-windows |
| Original viogpu3d PR (open since 2023, x64, GL + D3D10 only) | https://github.com/virtio-win/kvm-guest-drivers-windows/pull/943 |
| UTM display-only virtio-gpu driver | https://github.com/utmapp/virtio-gpu-wddm-dod |
| QEMUKit (Swift QMP) | https://github.com/utmapp/QEMUKit |
| CocoaSpice | https://github.com/utmapp/CocoaSpice |
| Tiny11 Builder | https://github.com/ntdevlabs/tiny11builder (default branch `winui-preview`; `docs/usage.md`, `NOTICE.md`, `recipes/cd700-custom.json`) |
| Apple Game Porting Toolkit | https://developer.apple.com/games/game-porting-toolkit/ |
| Windows answer files: `windowsPE` pass, `RunSynchronous` | https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/ |
| Winpeshl.ini | https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpeshlini-reference-launching-an-app-when-winpe-starts |
| DISM image management | https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14 |
| Windows.Graphics.Capture | https://learn.microsoft.com/windows/uwp/audio-video-camera/screen-capture |

## Verified facts

### UTM / graphics

- UTM 5.0 ships "DirectX graphics support for Windows": D3D11 via DXMT and
  D3D12 "when available" via D3DMetal; the driver is experimental with
  limited game compatibility; a fresh Windows install is recommended.
- Requirements stated: macOS 13+, a `-gl` display card, ANGLE (Metal)
  renderer. D3DMetal needs macOS 14+ and Rosetta on Apple silicon; without
  Rosetta UTM falls back to DXMT.
- UTM 5.0 also ships Venus (Vulkan 1.3) for Linux guests with MoltenVK
  recommended and KosmicKrisp experimental; and notes ARM64 QEMU VMs now
  always use GICv3.
- Neptune is a virglrenderer protocol alongside vrend/Venus that serialises
  D3D COM calls into a shared-memory ring; modelled on Venus.
- Triton is a WDDM D3D11 UMD that converts DDI calls back to D3D11 API calls
  (and DXBC back to DXContainer) and feeds Neptune; the KMD is based on
  anonymix007's Venus KMD branch; DWM composition works with shared textures.
- virglrenderer uses one `virgl_render_server` process per context; with
  D3DMetal that process runs x86_64 under Rosetta.
- Cross-process shared textures on macOS use `shm_open` memory mapped as
  `MTLBuffer` (linear textures only).
- D3DMetal's licence prevents bundling; UTM does not bundle it.
- UTM published a working QEMU command line for a Windows ARM64 guest:
  `-machine virt -accel hvf,ipa-granule-size=0x1000 -cpu host ...
  -device virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true
  -display cocoa,gl=es`, with edk2 pflash and an NVMe system disk, and env
  `ANGLE_DEFAULT_PLATFORM=metal`, `D3DMETAL_FRAMEWORK_PATH`.
- Windows drivers must be built on Windows; prebuilt signed drivers are
  published on the KMD repo's releases page.
- UTM's architecture: QEMU fork built as a shared library; on macOS launched
  in a separate process via an XPC helper (QEMUHelper → QEMULauncher);
  control over QMP; display via SPICE (CocoaSpice renders to Metal).
- UTM's guest tools support arm64 Windows and can install automatically
  during Windows Setup when mounted on a second CD drive.
- `d3dmetal-native` is MIT-licensed, x86_64-only, macOS 14+, and provides
  swapchains on an `NSView`/`CAMetalLayer` plus cross-process shared
  textures/fences.

### Tiny11 Builder

- Now a WinUI 3 / C# Windows app (0.2.0) with x64 and ARM64 builds; requires
  a Windows 10 2004+ host and Microsoft servicing tools (DISM; oscdimg found
  locally or downloaded from Microsoft); the original PowerShell scripts
  remain.
- Supports Windows 11 client x64/ARM64 images, 22H2 onward; not Server.
- Modes: Tiny11 (keeps Update, Defender, WinRE, Store, shared runtimes),
  Tiny11 Core (irreversible, unserviceable, test VMs only), Custom (recipes).
- The Tiny11 preset removes bundled apps, Edge/WebView2 and OneDrive
  binaries, and applies hardware-check, reserved-storage and
  automatic-encryption settings.
- No licence file; `NOTICE.md` says no licence has been assigned and that
  public availability does not grant redistribution rights.
- Known issue noted for ARM64 with the legacy script: a harmless error
  because ARM64 images lack `OneDriveSetup.exe` in System32.

### This machine

- Apple M3, macOS 27.3. `qemu-system-aarch64`, `swtpm` and `wimlib-imagex`
  are not installed.

## Not verified (re-check before depending on them)

- Everything about D3D12 on MoltenVK: whether vkd3d-proton builds natively
  for macOS, which Vulkan features it needs that MoltenVK lacks, and its
  licence terms. UTM's Neptune post only names vkd3d-proton as a *future*
  host backend, and its Triton post calls DXVK on MoltenVK unstable.
- QEMU upstream's current virtio-gpu documentation (the docs URL tried
  returned 404).
- Whether the UTM QEMU fork's `virtio-ramfb-gl` supports `max_outputs=2`
  together with Neptune.
- Signing method and redistribution terms of the prebuilt Neptune drivers.
- Licences of the DXMT fork and the Neptune-specific additions in each fork.
- Behaviour of `windowsPE` `RunSynchronous` on current 24H2+/26H2 ARM64 media.
- Windows.Graphics.Capture behaviour on the Triton driver.
- virtiofs/9p availability for a Windows ARM guest on a macOS host.
- Prism performance ratios quoted in 00 (estimates, to be replaced by bench
  results).
