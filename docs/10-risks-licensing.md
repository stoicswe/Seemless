# 10 — Risks, open questions, licensing

## Risk register

Severity × likelihood, highest first.

| # | Risk | Impact | Mitigation / decision point |
|---|------|--------|-----------------------------|
| R1 | **Triton/Neptune is experimental.** UTM itself warns of limited game compatibility and guest instability | Core promise (gaming) under-delivers | Spike S2 measures reality before anything else. Product messaging follows measured tiers (00). Contribute fixes upstream. Desktop/app use does not depend on game compatibility |
| R2 | **x64 emulation tax (Prism)** is outside our control | CPU-bound games run well below native | State it plainly. Benchmarks include an x64-vs-ARM64 ratio so we can tell users what to expect |
| R3 | **Kernel driver signing.** Our own KMD builds need Microsoft attestation signing (EV certificate, Hardware Dev Center) or test-signing with Secure Boot off | Blocks shipping our own driver builds; test-signing shows a watermark and weakens guest security | S2 determines how UTM's builds are signed. Until resolved, consume UTM's signed builds and keep Secure Boot off (D12). Budget time and cost for attestation before release |
| R4 | **D3D12 via MoltenVK has two unproven halves.** (a) vkd3d-proton expects a modern desktop Vulkan driver and MoltenVK does not implement all of it; UTM reports even DXVK on MoltenVK as unstable. (b) The guest still needs a D3D12 WDDM driver and Neptune D3D12 protocol, which upstream has announced but not shipped; if it does not arrive we write our own (M7b), which is the largest and most specialised piece of work in the project | Many 2022+ titles are D3D12-only | S8 measures the MoltenVK gap before any integration work. Budget for carrying MoltenVK/vkd3d-proton patches. KosmicKrisp is the alternative Vulkan driver (available on every supported Mac, since we require macOS 26). D3DMetal remains an optional user-supplied fallback. Host-side work starts now and is testable without a guest driver. M7b has an explicit trigger, a bring-up ladder, and never blocks M1–M6. Do not promise D3D12 until a real title runs |
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
| Q8 | (Owner, 2026-11-24: Q8, Q10 and Q11 are answered last, after the other work) Which Windows edition do we recommend (Home vs Pro)? Pro adds Group Policy for update/driver control | M2 |
| Q9 | Should the app be sandboxed at release? | M8 |
| Q10 | ~~Project licence: stay MIT for our own code?~~ **Answered (owner, 2026-11-24): MIT** for our own code. Upstream projects keep their own licences (QEMU GPL-2.0, swtpm, Mesa, vkd3d-proton LGPL, MoltenVK Apache-2.0, and so on). No Windows ISOs or images are distributed; users bring their own | Done |
| Q11 | Product name spelling: repo is "Seemless" | Owner's call; code uses `Seemless`/`seemless` consistently |
| Q12 | Can the agent binaries we publish be built with the CRT/SDK that cargo-xwin downloads, under Microsoft's licence terms (static CRT; which redistribution terms apply)? | Before Preview 1 (public release) |
| Q13 | How do preview users get the Neptune guest drivers: bundle UTM's signed v0.6 release (see Q1), have the app download it from UTM's release on the user's Mac, or ship our own WP4.6 builds (signing, D12)? | Before Preview 1 (public release) |

## Licensing and legal constraints

This section is engineering guidance, not legal advice. Have release
packaging reviewed.

| Component | Licence (verify at pin time) | How we use it | Obligation |
|-----------|------------------------------|---------------|------------|
| Our code | MIT (current repo `LICENSE`) | — | — |
| QEMU (UTM fork) | GPLv2 (parts LGPL/BSD) | Separate executable, launched as a child process, talked to over sockets | Ship licence text; provide complete corresponding source for the exact build (our fork SHA + `patches/qemu`); do not link QEMU code into the app |
| virglrenderer | MIT | Linked by QEMU / render server | Notice |
| DXMT | LGPL-2.1-or-later (read from `LICENSE`, 2026-11-23) | Dylib loaded by render server | LGPL: keep it a separately replaceable dylib; ship licence and source for our exact build |
| d3dmetal-native | MIT (checked 2026-11-23) | Optional dylib | Notice |
| D3DMetal.framework | Apple proprietary (Game Porting Toolkit licence) | **Optional, user-supplied only**; not part of the planned D3D12 path | Never bundle or download; explain terms in UI |
| MoltenVK, ANGLE, libepoxy | Apache-2.0 / BSD / MIT | Bundled libs | Notices |
| vkd3d-proton | LGPL-2.1 (GitHub metadata, 2026-11-23) | Bundled dylib loaded by the render server (D3D12 → Vulkan) | Keep it a separate, replaceable dylib; ship licence and source for our exact build including patches |
| swtpm / libtpms | BSD-3 | Child process | Notice |
| glib, libslirp, pixman, libusb | LGPL / BSD / MIT | Dynamically linked by QEMU | LGPL: keep them as replaceable dylibs |
| Libraries QEMU and swtpm link (GLib, gvdb, proxy-libintl, JSON-GLib, PCRE2, OpenSSL 3.5, libslirp, pixman, libpng, libjpeg-turbo) | LGPL-2.1+ (GLib, gvdb, JSON-GLib), LGPL-2.0+ (proxy-libintl), BSD / MIT / Apache-2.0 / IJG / libpng (the rest) | Built from pinned source by `build-deps.sh` (P1, 2026-11-24); dylibs in `Contents/Frameworks` | Notices; source in the source offer; LGPL ones are replaceable dylibs (re-signing needed) |
| Windows guest drivers (kvm-guest-drivers-windows forks) | BSD-2-Clause as reported for `osy/kvm-guest-drivers-windows` (2026-11-23) | In tools ISO | Notice; check fork additions |
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
6. The edk2 firmware from UTM's QEMU build shows UTM's logo at boot (seen
   2026-11-23). Build our own firmware with our own (or no) logo before
   release.

### Release packaging findings (WP8.1/8.2/8.5, 2026-11-24)

Found while building the first self-contained app (`docs/release.md`).
Flagged for the owner; none decided here.

- **L1 — macOS 26 support vs Homebrew. Resolved (owner, 2026-11-24:
  "build from source").** On this macOS 27 Mac, 14 bundled Homebrew dylibs
  needed macOS 27. The libraries are now built from pinned source for 26.0
  (`build-deps.sh`), and QEMU drops gnutls, SDL, libusb and zstd (option A,
  docs/02). The audit passes with no exceptions (28 Mach-O files, all
  minos ≤ 26.0); `bundle_stack.py` refuses any Homebrew library.
- **L2 — Homebrew versions not pinned. Resolved** with L1: every library is
  in `versions.lock` and in the source offer from its pinned commit.
- **L3 — (L)GPL-3.0 parts. Cleared** with L1: gnutls and with it gmp,
  nettle, libunistring, libidn2, libtasn1 and p11-kit are no longer in the
  app. The remaining copyleft libraries are LGPL-2.x (GLib, gvdb,
  JSON-GLib, proxy-libintl, DXMT, vkd3d-proton), as replaceable dylibs.
- **L4 — iPXE.** `efi-virtio.rom` (QEMU's prebuilt, from `roms/ipxe`) is
  GPL-2.0-or-later/UBDL; its source is in the source offer.
- **L5 — libtpms TPM 2.0 code**: TCG BSD-style licence, redistribution with
  notice allowed; it states that no patent licence is granted.
- **L6 — virglrenderer Neptune files**: per-file headers not yet read.

## Distribution

- Preview 1: DMG and zip signed with a self-signed certificate, not
  notarized (owner, 2026-11-24); testers allow the app once in System
  Settings. Later: Developer ID-signed and notarized
  (`scripts/package-release.sh`, `docs/release.md`); Sparkle updates later
  (WP8.3).
- Entitlements (WP8.2, checked 2026-11-24): `com.apple.security.hypervisor`
  on `qemu-system-aarch64` only. No `allow-jit`: we only run `-accel hvf`,
  and the firmware boots under the hardened runtime without it. No
  library-validation or DYLD exceptions in Developer ID builds. Ad-hoc and
  self-signed builds (Preview 1) add `disable-library-validation`, because
  that code has no Team ID; this weakens protection against injected
  libraries until a Developer ID replaces the self-signed certificate. `com.apple.vm.networking` only if granted.
- Mac App Store is out: sandbox constraints on child processes,
  optional user-supplied frameworks loaded at runtime, and GPL terms.
