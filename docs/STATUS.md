# Status

Updated: 2026-11-23 (after WP3.0 VM manager app)

## Done

- Phase 1 planning documents (`docs/00`–`11`), `CLAUDE.md`.
- **WP0.1 repo scaffolding** (2026-11-23):
  - Directory layout from `docs/01` with README stubs.
  - `scripts/bootstrap.sh` (tool check, milestone-grouped), `scripts/check.sh`
    (all VM-free checks), `.github/workflows/ci.yml` (runs `check.sh`).
  - `kit/`: `SeemlessKit` (`StorageLayout` from docs/02), `seemlessctl`
    (`--version`, `paths`), 4 Swift tests passing.
  - `guest/agent/`: Rust workspace with the 8 crates from docs/06, toolchain
    pinned to 1.99.1; builds and tests on macOS (no tests yet).
  - `scripts/versions.lock`: candidate SHAs for every upstream source,
    unbuilt; `THIRD_PARTY.md` with licences as GitHub reports them.
- **S1 host stack build** (2026-11-23): every component builds from pinned
  SHAs, arm64, minos 26.0; QEMU boots to firmware with the production GPU
  device, swtpm TPM 2.0 and QMP (headless and windowed). Findings and
  deviations: `docs/spikes/S1-host-stack-build.md`.
- **M1 VM runtime core** (2026-11-23): `VMConfig` + QEMU command generation
  (snapshot-tested against docs/02), QMP client, disk/firmware tooling,
  `VMProcess` lifecycle, `VMRemote`, and the `seemlessctl vm`/`disk`/`stack`
  commands. Tested by booting real QEMU to firmware (no Windows needed).
- **M2 image pipeline, ISO-free parts** (2026-11-23): ISO/WIM inspector,
  payload disk builder, answer files, `apply.cmd`, first-boot scripts,
  Keychain credentials, `seemlessctl image build`. Plumbing dry-run done with
  a fake ISO; nothing has run against real Windows media.
- **WP3.0 VM manager app** (2026-11-23, owner request): SwiftUI app in
  `app/` (Liquid Glass, macOS 26+), built by `scripts/build-app.sh` into
  `build/app/Seemless.app`. Kit additions: `VMManager` (one controller for
  VMs started here or elsewhere), boot settings (order, TPM on/off, firmware
  menu wait), persisted media, `BootKeys` (Escape → firmware setup, Space →
  CD prompt), restart, UEFI/TPM reset. CLI: `vm set`, `vm restart`,
  `vm media`, `vm firmware`, `vm screendump`, `vm run --firmware-setup|--cd-prompt`.
  Firmware setup and firmware wait checked by QMP screendump; app checked by
  window screenshots (stopped and running states). Nobody has clicked
  through the app yet.
- 64 Swift tests, all passing (run repeatedly to catch races).
- Upstream research: UTM 5.0's Neptune/Triton DirectX stack and Tiny11
  Builder 0.2.0 state (see `11-references.md`).

## Not done

- No real Windows has booted yet: `apply.cmd`, `firstboot.cmd` and the
  answer files are untested (S4). Runbook: `docs/testing/first-iso.md`.
- Suspend/resume-from-disk (S6), removal recipe (WP2.3), sealing a golden
  image, guest agent (M4) not started. App: VM manager only; display,
  helper, onboarding flow, menu bar extra not started.
- App actions that start a VM from the app (buttons, sheets) were not
  clicked in this session: they call the same `VMManager` paths the tests
  cover, but the UI wiring itself is unverified by hand.
- No vendored sources (S1 uses build-time checkouts in `build/src`).
- virglrenderer, Venus and Neptune have not run: QEMU starts the renderer
  only when a guest driver talks to it (S2).
- CI workflow written but never run on GitHub.
- Windows-target build of the agent not checked (target not installed).
- Spikes S2–S8 not run. Every "Provisional" decision in
  `01-architecture.md` is unproven.
- Nothing in the plan has been tested on hardware.

## Next

When the ISO is here (follow `docs/testing/first-iso.md`; the app's New VM
sheet runs the same automatic or manual install):
1. S4 — `seemlessctl image build`; debug `apply.cmd` from `apply.log`.
2. S2 — manual install + UTM's 3D driver; Fire Strike, driver signing.

Without an ISO:
3. S8 — D3D12-on-MoltenVK feasibility (paused 2026-11-23 to finish the VM
   runtime; only the driver check was done: MoltenVK 1.4.2 is the only
   Vulkan driver installed, Homebrew has no KosmicKrisp).
4. S3 — display export; evaluate QEMU's built-in `-display dbus` first.
5. M4 groundwork — protocol + mock agent (WP4.1) needs no Windows either.

## Learned

- This Mac: M3, 4 performance + 4 efficiency cores, 24 GB, macOS 27.3,
  Xcode 27.3 beta, Swift 6.4.2.
- virglrenderer defaults to **D3DMetal** when `NPT_BACKEND` is unset; the
  launcher always sets it (`dxmt` by default).
- QEMU serves one client per QMP monitor; we run two (owner + controllers).
- Homebrew's Rust (1.100.0) shadows rustup's on PATH. Seemless scripts call
  `~/.cargo/bin/cargo` directly. Fix permanently by reordering PATH or
  `brew uninstall rust`.
- cargo-xwin's first Windows build downloads Microsoft's CRT/SDK and requires
  accepting Microsoft's licence: that is the owner's decision.
- UTM's build notes pin ANGLE to WebKit commit `6a7f464…` and need LLVM 15,
  pkg-config and the Metal toolchain (all checked by `bootstrap.sh`).

## Needs the owner's input

- A Windows 11 ARM64 ISO on this machine (for S2/S4).
- (Optional) Apple's Game Porting Toolkit, only if we want D3DMetal numbers
  to compare against the MoltenVK path.
- Open questions Q8, Q10, Q11 in `10-risks-licensing.md`.

## Log

| Date | Session | Result |
|------|---------|--------|
| 2026-11-23 | Planning | Docs written; no spikes run |
| 2026-11-23 | Planning | Owner decision: D3D12 maps through MoltenVK (vkd3d-proton), D3DMetal optional only. Docs updated; S8 added |
| 2026-11-23 | Planning | Owner decision: begin now; write our own guest D3D12 driver if upstream's does not arrive (D3b, M7b added) |
| 2026-11-23 | WP0.1 | Scaffolding done; acceptance check passes (exit 0) |
| 2026-11-23 | S1 (in progress) | Owner decision: macOS 26 minimum (D10). Package, build scripts (deployment target 26.0), CI and docs updated |
| 2026-11-23 | S1 | Host stack builds and smoke-boots to firmware; 9 deviations recorded; renderer runtime unproven until S2 |
| 2026-11-23 | M1 + M2 (ISO-free) | VM runtime and image pipeline built; 53 tests; bugs found and fixed: blocking socket reads starving the concurrency pool, uncancellable waits, single-client QMP, recursive state description |
| 2026-11-23 | WP3.0 | VM manager app + `VMManager`, boot/firmware settings, media; 64 tests; firmware menu and wait verified by screendump |
