# 01 — Architecture

## System diagram

```
┌──────────────────────────── macOS host (Apple silicon) ─────────────────────────────┐
│                                                                                     │
│  Seemless.app  (Swift, SwiftUI + AppKit, Metal)                                     │
│  ┌──────────────┐ ┌──────────────┐ ┌───────────────┐ ┌───────────────────────────┐ │
│  │ Onboarding / │ │ Window       │ │ Integration   │ │ SeemlessKit               │ │
│  │ Library UI   │ │ Bridge       │ │ (Dock, files, │ │  VMConfig → QEMU argv     │ │
│  │              │ │ (NSWindow    │ │ clipboard,    │ │  VMProcess, QMPClient     │ │
│  │              │ │ per HWND)    │ │ notifications)│ │  AgentClient, ImageBuild  │ │
│  └──────────────┘ └──────┬───────┘ └───────┬───────┘ └───────┬───────────────────┘ │
│                          │ frames (IOSurface)│ agent msgs      │ spawn / QMP        │
│  ┌───────────────────────┴───────────────────┴─────────────────┴─────────────────┐ │
│  │ SeemlessVMHelper (XPC service; holds com.apple.security.hypervisor)          │ │
│  │   ├─ qemu-system-aarch64  (patched fork, GPLv2, separate executable)         │ │
│  │   │     ├─ virtio-gpu (venus + neptune)  ──► virgl_render_server processes   │ │
│  │   │     │                                     └─ DXMT | vkd3d+MoltenVK ► Metal│ │
│  │   │     ├─ ui/seemless display backend ──► IOSurface ring over Mach ports    │ │
│  │   │     ├─ virtio-serial ports (agent control, clipboard bulk)               │ │
│  │   │     └─ nvme, virtio-net, usb-xhci, audio, tpm-tis, pflash (edk2)         │ │
│  │   └─ swtpm (TPM 2.0 emulator)                                                │ │
│  └───────────────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────┬─────────────────────────────────────────────┘
                                        │ HVF
┌───────────────────────────────────────┴───── Windows 11 ARM64 guest ────────────────┐
│  viogpu3d KMD + Triton UMD (D3D11)  ·  Venus ICD (Vulkan, later)                    │
│  virtio drivers: netkvm, vioserial, viofs, viosnd/USB audio                         │
│  seemless-agent-svc (LocalSystem)  ──spawns──►  seemless-agent (per user session)   │
│     window tracking · WGC capture → atlas display · input assist · clipboard        │
│     app catalogue · file open · notifications · power/time · updates                │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Language | Lives in | Responsibility |
|-----------|----------|----------|----------------|
| `Seemless.app` | Swift | `app/` | UI, window bridge, macOS integration |
| `SeemlessKit` | Swift package | `kit/` | Everything testable without UI: config, QEMU launch, QMP, agent client, image builder, storage |
| `seemlessctl` | Swift (ArgumentParser) | `kit/Sources/seemlessctl` | Headless CLI over SeemlessKit. **Every feature lands here first** so it can be tested from a terminal and by agents |
| `SeemlessVMHelper` | Swift | `app/Helper` | XPC service that owns the QEMU, swtpm and render-server child processes |
| QEMU fork | C | `vendor/qemu` (submodule) + `patches/qemu/` | Hypervisor and device model |
| virglrenderer, DXMT, vkd3d-proton, MoltenVK, ANGLE, libepoxy (d3dmetal-native optional) | C/C++ | `vendor/*` (submodules, pinned) | Host graphics stack |
| `seemless-agent`, `seemless-agent-svc` | Rust | `guest/agent` | Guest-side integration |
| Guest drivers | C/C++ | `vendor/` submodules; binaries built in a Windows build VM | KMD/UMD, virtio |
| Guest tools installer | Rust + scripts | `guest/tools` | Builds `seemless-tools.iso` |
| Image recipes | JSON/XML/cmd | `image/` | Unattend templates, removal recipe, WinPE apply script |
| Protocol | Protobuf | `proto/` | Host↔agent schema, single source of truth |
| Build scripts | Shell/Python | `scripts/` | Reproducible dependency builds |

## Repository layout (target)

```
Seemless/
├── CLAUDE.md                 # rules for implementing sessions
├── README.md
├── docs/                     # this plan; keep current as decisions change
├── app/                      # Xcode project: Seemless.app + SeemlessVMHelper
├── kit/                      # Swift package: SeemlessKit + seemlessctl + tests
├── proto/                    # *.proto
├── guest/
│   ├── agent/                # Rust workspace (cross-compiled from macOS)
│   └── tools/                # guest tools ISO assembly
├── image/
│   ├── unattend/             # autounattend.xml / unattend.xml templates
│   ├── recipes/              # seemless-default.json, seemless-gaming.json
│   └── winpe/                # apply-and-debloat script run in WinPE
├── patches/                  # our patch series per vendored project
│   └── qemu/
├── vendor/                   # git submodules, pinned SHAs
├── scripts/                  # bootstrap.sh, build-deps.sh, build-qemu.sh ...
└── build/                    # gitignored outputs; build/prefix is the dep sysroot
```

## Process and trust model

- `Seemless.app` is sandbox-free in early milestones (Developer ID, hardened
  runtime). Sandboxing is a M8 decision.
- `SeemlessVMHelper` is the only signed binary carrying
  `com.apple.security.hypervisor`. It launches QEMU as a child. QEMU being a
  separate GPLv2 executable keeps the licence boundary clean (UTM does the
  same with QEMUHelper → QEMULauncher).
- virglrenderer spawns one `virgl_render_server` per guest graphics context.
  A render-server crash must not kill the VM. DXMT and vkd3d-proton/MoltenVK
  render servers are native arm64. Only the optional D3DMetal backend needs an
  x86_64 render server under Rosetta.
- The guest is **untrusted**. Everything the agent sends is validated on the
  host: sizes, rectangles, paths, counts. The agent never causes the host to
  open a file or URL without a host-side policy check
  (see [06-guest-agent-protocol.md](06-guest-agent-protocol.md)).

## Channels between host and guest

| Channel | Transport | Used for |
|---------|-----------|----------|
| Control | QMP unix socket | Power, snapshots, device hotplug, balloon |
| Agent control | virtio-serial port `app.seemless.agent.0` | Protobuf messages, low volume, ordered |
| Agent bulk | virtio-serial port `app.seemless.bulk.0` | Clipboard payloads, icons, drag-and-drop file streams |
| Display 0 | virtio-gpu scanout 0 → IOSurface | Windows desktop (desktop and game modes) |
| Display 1 (atlas) | virtio-gpu scanout 1 → IOSurface | Per-window pixels for seamless mode |
| Input | QEMU input devices driven by the host over QMP `input-send-event` (D4) | Keyboard, absolute tablet, relative mouse, wheel |
| Files | virtiofs (or SMB fallback) | Shared folders |
| Audio | QEMU audio device → CoreAudio | Playback and capture |

## Decision log

Status values: **Decided**, **Provisional** (needs a named spike in
[09-roadmap.md](09-roadmap.md) before we depend on it), **Open**.

| ID | Decision | Status | Why |
|----|----------|--------|-----|
| D1 | QEMU + HVF, not Virtualization.framework | Decided | VZ does not support Windows guests or custom devices; our GPU path is a virtio-gpu extension |
| D2 | Base on **UTM's QEMU fork** (`utmapp/qemu`, `utm-edition`), pinned, plus our own small patch series | Decided | It already carries the Neptune virtio-gpu capset, macOS GL/Metal plumbing and `hvf,ipa-granule-size` |
| D3 | D3D11 via Neptune/Triton with DXMT as the host backend | Decided | Only working open D3D11 path for Windows-on-QEMU-on-macOS |
| D3a | **D3D12 is mapped through MoltenVK**: Neptune D3D12 calls → vkd3d-proton on the host → Vulkan → MoltenVK → Metal. Fully bundled, native arm64, no Rosetta | Decided (owner, 2026-11-23); feasibility: S8 says **patch**, with KosmicKrisp the better base (2026-11-23). **Driver: MoltenVK** (owner, 2026-11-23, over S8's KosmicKrisp recommendation). KosmicKrisp stays the documented alternative; the driver is swappable (`VKD3D_VULKAN_LIBRARY`; no Vulkan loader in this path). **WP7.5 (2026-11-24): a D3D12 device on patched MoltenVK, FL 11_0 / SM 6.0, no capability bypass** ([spikes/WP7.5-d3d12-host-backend.md](spikes/WP7.5-d3d12-host-backend.md)) | Open-source and redistributable, unlike D3DMetal. D3DMetal stays an optional user-supplied alternative, never a requirement. S8 ([spikes/S8-d3d12-moltenvk.md](spikes/S8-d3d12-moltenvk.md)): vkd3d-proton builds natively with a small port patch. Neither driver gives a device unmodified: MoltenVK 1.4.2 lacks 4 hard requirements, KosmicKrisp (Mesa 26.3.1) lacks 2 (transform feedback, 1-texel buffer alignment), and both of those are patchable in vkd3d-proton. With the checks bypassed: MoltenVK 461/578 tests at FL 11_0, KosmicKrisp 510/578 at FL 11_1, both SM 6.0, and the demos render on both. FL 12_0 / SM 6.x need sparse residency, denorm controls, int64 atomics and more |
| D3b | Guest D3D12 driver: use upstream's if it ships; **write our own D3D12 UMD + Neptune D3D12 protocol if necessary**, reusing the existing KMD. Host-side D3D12 work starts now regardless | Decided (owner, 2026-11-23). **Trigger reviewed 2026-11-23 (WP7b.0): not fired.** Upstream ships it: Triton has a D3D12 DDI and v0.6 exports `OpenAdapter12`. We use upstream's and supply the host vkd3d-proton library (WP7.5) | D3D12 must not be hostage to another project's schedule; trigger and design in 04; review in [spikes/WP7b0-d3d12-trigger-review.md](spikes/WP7b0-d3d12-trigger-review.md) |
| D4 | Do **not** use SPICE or QEMU's `-display dbus`. Add a small QEMU display backend (`ui/seemless`) that exports scanouts as a ring of IOSurfaces handed over as Mach send rights via a bootstrap name; input goes over QMP `input-send-event` | Decided (S3, 2026-11-23); built as `patches/qemu/0001` in WP3.1, Metal path verified 2026-11-24 | dbus cannot drive the GL device on macOS (no EGL, no macOS texture export, no Mach ports). Spike hand-off costs ~0.1 ms; +6 ms key→glass vs `cocoa` when drawing on frame arrival ([S3 note](spikes/S3-display-export.md)) |
| D5 | Seamless pixels via WGC per-window capture blitted to an **atlas** on scanout 1 | Provisional (S5) | Solves occlusion without modifying the GPU driver |
| D6 | Agent in Rust, cross-compiled from macOS (`aarch64-pc-windows-msvc` via `cargo-xwin`) | Decided | No Windows machine needed for the agent inner loop |
| D7 | Host↔agent protocol: length-prefixed Protobuf over virtio-serial | Decided | vioserial is a mature signed driver; schema shared by Swift and Rust |
| D8 | Image built by **apply-time debloat in WinPE** from the user's stock ISO, following the Tiny11 removal set as a recipe | Decided (S4, 2026-11-23) | Tiny11 Builder is Windows-only and has no licence; see 03 |
| D9 | x86/x64 apps run via Windows' own Prism | Decided | Nothing to build |
| D10 | Host app in Swift; **minimum macOS 26**; Apple silicon only | Decided (owner, 2026-11-23) | One modern baseline: current Metal for MoltenVK and the render servers, KosmicKrisp (needs macOS 26) available on every supported Mac, current AppKit/SwiftUI APIs. Every binary we build, including dependencies, targets `MACOSX_DEPLOYMENT_TARGET=26.0` |
| D11 | Distribution: Developer ID + notarization, outside the App Store | Decided | GPL child processes, optional user-supplied frameworks |
| D12 | **UTM's prebuilt drivers need neither test-signing nor a Secure-Boot change**: they are Microsoft **attestation-signed** (HWCC catalog) plus embedded EV signatures (Turing Software LLC), so they load under standard ARM64 code integrity. Test-signing + Secure-Boot-off apply only to **our own** unsigned builds before attestation (WP4.6); our firmware runs without Secure Boot regardless | Decided for the UTM path (S2, 2026-11-23); empirical load-in-guest still unrun | Signatures read from the v0.6 release binaries. For own-built drivers, production still needs an EV cert + Hardware Dev Center attestation ([S2 note](spikes/S2-windows-graphics.md)) |
| D13 | Guest window chrome stays Windows-drawn; host windows are borderless with macOS shadow | Decided | Matches user expectation from Parallels; avoids per-app non-client hacks |
