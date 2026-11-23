# 10 — Risks, open questions, licensing

## Risk register

Severity × likelihood, highest first.

| # | Risk | Impact | Mitigation / decision point |
|---|------|--------|-----------------------------|
| R1 | **Triton/Neptune is experimental.** UTM itself warns of limited game compatibility and guest instability | Core promise (gaming) under-delivers | Spike S2 measures reality before anything else. Product messaging follows measured tiers (00). Contribute fixes upstream. Desktop/app use does not depend on game compatibility |
| R2 | **x64 emulation tax (Prism)** is outside our control | CPU-bound games run well below native | State it plainly. Benchmarks include an x64-vs-ARM64 ratio so we can tell users what to expect |
| R3 | **Kernel driver signing.** Our own KMD builds need Microsoft attestation signing (EV certificate, Hardware Dev Center) or test-signing with Secure Boot off | Blocks shipping our own driver builds; test-signing shows a watermark and weakens guest security | S2 determines how UTM's builds are signed. Until resolved, consume UTM's signed builds and keep Secure Boot off (D12). Budget time and cost for attestation before release |
| R4 | **D3D12 via MoltenVK has two unproven halves.** (a) vkd3d-proton expects a modern desktop Vulkan driver and MoltenVK does not implement all of it; UTM reports even DXVK on MoltenVK as unstable. (b) The guest still needs a D3D12 WDDM driver and Neptune D3D12 protocol, which upstream has announced but not shipped; if it does not arrive we write our own (M7b), which is the largest and most specialised piece of work in the project | Many 2022+ titles are D3D12-only | S8 measures the MoltenVK gap before any integration work. Budget for carrying MoltenVK/vkd3d-proton patches. KosmicKrisp is the alternative Vulkan driver on macOS 26+. D3DMetal remains an optional user-supplied fallback. Host-side work starts now and is testable without a guest driver. M7b has an explicit trigger, a bring-up ladder, and never blocks M1–M6. Do not promise D3D12 until a real title runs |
| R5 | **Atlas capture may not work as designed** (WGC on this driver, second scanout, consent/border behaviour, cost) | Seamless falls back to crop tier with occlusion limits | S5 early. Tiered pixel-source design (05) means the bridge is not wasted either way |
| R6 | **Apply-time unattended install** may not work on current ARM64 media | Image pipeline needs the `boot.wim` modification fallback or path C | S4 early; fallback documented in 03 |
| R7 | **Tiny11 Builder has no licence** and is Windows-only | Cannot bundle or port its code | We implement our own recipe engine and treat Tiny11 as a behavioural reference; support user-built Tiny11 ISOs; ask the author for an explicit licence or permission |
| R8 | **Upstream churn.** We depend on five fast-moving forks (QEMU, virglrenderer, DXMT, drivers, Mesa UMD) | Rebase cost, breakage | Pin by SHA; keep our QEMU patches small and outside virtio-gpu; bench suite gates bumps |
| R9 | **Fast resume** may be impossible with GPU state (no migration of blob resources) | G5 missed; cold boots only | S6. Options: keep paused in RAM, guest hibernate, or accept ~15 s cold boot with an auto-start-at-login option |
| R10 | **Focus and input edge cases** in seamless mode (foreground lock, UAC, elevated windows, IME) | Daily-use papercuts that make it feel non-native | UIAccess agent, activation handshake, explicit test list (05); desktop mode always available as an escape hatch |
| R11 | **vmnet entitlement** not granted | Slirp only: no inbound connections, weaker performance | Slirp default with port forwards; revisit |
| R12 | **Windows updates re-bloat or break** the image (feature updates, driver replacement by Windows Update) | Regressions in the field | Agent re-applies recipe after feature updates; block driver updates for our device IDs via policy; overlay reset is the recovery path |
| R13 | **Memory pressure** on 8–16 GB Macs (guest RAM + GPU + render servers) | Swapping, poor experience | Minimum spec 16 GB recommended; pause policy; balloon in M7; show a clear warning on 8 GB machines |
| R14 | **Security of the bridge.** A compromised guest could abuse clipboard, file open, notifications | Host compromise or data leak | Validation rules in 06; shares are opt-in and narrow; no host command execution from guest messages, ever |
| R15 | **Anti-cheat and DRM** | Popular multiplayer titles do not run | Non-goal; say so in onboarding and in the launcher when a known-blocked title is detected |
| R16 | **Scope.** This is several products (VM runtime, image builder, window bridge, integrations) | Never reaching a usable whole | The milestone order delivers a usable desktop-mode product at M3 and seamless at M5; everything later is additive |

## Open questions

| # | Question | Resolve by |
|---|----------|-----------|
| Q1 | How are UTM's released Neptune drivers signed, and can they be redistributed in our tools ISO under their licences? | S2 |
| Q2 | IOSurface hand-off between QEMU and the app: mach port over XPC vs global `IOSurfaceID` lookup | S3 |
| Q3 | Does the UTM QEMU fork's virtio-gpu device support two outputs with Neptune, and what is the max scanout size? | S5 |
| Q4 | Suspend/resume mechanism | S6 |
| Q5 | Shared folder mechanism | S7 |
| Q6 | Does macOS Game Mode benefit child processes of the fullscreen app? | M7 |
| Q7 | Can WebView2 Evergreen and the VC++/DirectX redistributables be bundled in our tools ISO, or must they be downloaded in-guest? | M2 (read each licence) |
| Q8 | Which Windows edition do we recommend (Home vs Pro)? Pro adds Group Policy for update/driver control | M2 |
| Q9 | Should the app be sandboxed at release? | M8 |
| Q10 | Project licence: stay MIT for our own code? (repo `LICENSE` is currently MIT) | Before first public release |
| Q11 | Product name spelling: repo is "Seemless" | Owner's call; code uses `Seemless`/`seemless` consistently |

## Licensing and legal constraints

This section is engineering guidance, not legal advice. Have release
packaging reviewed.

| Component | Licence (verify at pin time) | How we use it | Obligation |
|-----------|------------------------------|---------------|------------|
| Our code | MIT (current repo `LICENSE`) | — | — |
| QEMU (UTM fork) | GPLv2 (parts LGPL/BSD) | Separate executable, launched as a child process, talked to over sockets | Ship licence text; provide complete corresponding source for the exact build (our fork SHA + `patches/qemu`); do not link QEMU code into the app |
| virglrenderer | MIT | Linked by QEMU / render server | Notice |
| DXMT | Verify (believed zlib/libpng-style, like DXVK) | Dylib loaded by render server | Notice |
| d3dmetal-native | MIT (checked 2026-11-23) | Optional dylib | Notice |
| D3DMetal.framework | Apple proprietary (Game Porting Toolkit licence) | **Optional, user-supplied only**; not part of the planned D3D12 path | Never bundle or download; explain terms in UI |
| MoltenVK, ANGLE, libepoxy | Apache-2.0 / BSD / MIT | Bundled libs | Notices |
| vkd3d-proton | LGPL-2.1 (verify at pin time) | Bundled dylib loaded by the render server (D3D12 → Vulkan) | Keep it a separate, replaceable dylib; ship licence and source for our exact build including patches |
| swtpm / libtpms | BSD-3 | Child process | Notice |
| glib, libslirp, pixman, libusb | LGPL / BSD / MIT | Dynamically linked by QEMU | LGPL: keep them as replaceable dylibs |
| Windows guest drivers (kvm-guest-drivers-windows forks) | BSD-3 (upstream virtio-win) | In tools ISO | Notice; check fork additions |
| Mesa-derived UMD (Triton/Neptune guest) | MIT | In tools ISO | Notice |
| UTM (app), CocoaSpice, QEMUKit | Apache-2.0 | Reference; optional dependency | Notice if any code is used |
| Tiny11 Builder | **None stated** | Reference only | Do not copy code or bundle binaries |
| Windows 11 | Microsoft EULA | User-supplied ISO, user's licence | Never redistribute images, ISOs, keys or Microsoft tools (DISM, oscdimg). Never bypass activation. Microsoft's support statement for Windows 11 Arm on Apple silicon names specific authorised solutions; we are not one, so make no "supported by Microsoft" claim |
| Microsoft redistributables | Per-package redistribution terms | Tools ISO or in-guest download | Q7 |

Rules that follow:

1. GPL code stays in separate processes and separate source trees
   (`vendor/`, `patches/`). Never paste QEMU code into `kit/` or `app/`.
2. Every vendored dependency gets an entry in `THIRD_PARTY.md` with SHA,
   licence and source URL at the time it is added (start in S1).
3. The release artefact includes a written source offer or a direct link to
   the exact sources and build scripts for all GPL/LGPL components.
4. No Microsoft or Apple proprietary binaries in the repository or the app
   bundle, ever.
5. Marketing and UI: "Windows" is used descriptively; no Microsoft or Apple
   logos; no claims of endorsement.

## Distribution

- Developer ID-signed, notarized DMG; Sparkle updates (M8).
- Entitlements: `com.apple.security.hypervisor` on the helper;
  `com.apple.security.cs.allow-jit` if QEMU's TCG paths are compiled in
  (prefer building HVF-only to avoid it); `com.apple.vm.networking` only if
  granted.
- Mac App Store is out: sandbox constraints on child processes,
  optional user-supplied frameworks loaded at runtime, and GPL terms.
