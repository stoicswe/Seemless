# 09 — Roadmap and work packages

Milestones are ordered by dependency. Each work package (WP) is sized for one
implementation session and has an explicit acceptance check that can be run
from a terminal. A session should take one WP, read the docs listed under
"Read first", and finish with the acceptance check passing and
`docs/STATUS.md` updated.

Conventions:

- **Spikes (S*)** answer a question and produce a short findings note in
  `docs/spikes/S<n>-<slug>.md` plus throwaway code under `spikes/`. They
  update the decision log in 01 (Provisional → Decided, or a new decision).
- A WP that discovers its design is wrong stops and updates the doc first.
- Nothing in a later milestone starts before the spikes it depends on.

Legend: ✅ done and tested on this Mac · ◐ partly done, see the row.
Testing with real Windows media: `docs/testing/first-iso.md`.

## M0 — Toolchain and spikes

Goal: prove the three risky pillars on this machine before writing product code.

| ID | Work | Read first | Acceptance |
|----|------|-----------|------------|
| WP0.1 ✅ | Repo scaffolding: directory layout (01), `.gitignore`, `scripts/versions.lock`, `scripts/bootstrap.sh` (checks Xcode, Rust, cargo-xwin, meson, ninja, Rosetta), empty Swift package and Rust workspace that build, CI workflow for the pure-logic tests | 01 | `scripts/bootstrap.sh && swift build --package-path kit && cargo check --manifest-path guest/agent/Cargo.toml` succeed |
| S1 ✅ | Build the host graphics stack and QEMU fork from pinned sources into `build/prefix` (`scripts/build-deps.sh`, `scripts/build-qemu.sh`) following UTM's Triton build notes | 02, 04, 11 | `build/prefix/bin/qemu-system-aarch64 --version` runs; `-device help` lists `virtio-ramfb-gl`; findings note records every deviation from UTM's instructions and all licences encountered |
| S2 ◐ | Manual Windows bring-up: install Windows 11 ARM64 by hand with `-display cocoa,gl=es`, install UTM's pre-built Neptune/Triton drivers, run `dxdiag` and 3DMark Fire Strike on DXMT | 04 | Fire Strike completes; note records scores, driver signing method (answers D12), Secure Boot/test-signing requirements, instabilities seen |
| S3 ✅ | Display export: prototype `ui/seemless` far enough to show scanout 0 in a standalone Swift/Metal test app via IOSurface, with input going back | 04 | Test app shows the Windows desktop at display refresh and can click the Start button; note records IOSurface hand-off method and measured added latency vs `cocoa` |
| S4 ✅ | Unattended apply-time install: `autounattend.xml` + `apply.cmd` on stock 24H2/25H2 ARM64 media, no debloat yet | 03 | From a blank qcow2 to a logged-on desktop with zero keystrokes; note says whether `windowsPE` `RunSynchronous` works or the `boot.wim`/`winpeshl.ini` fallback was needed |
| S5 | Atlas feasibility: second scanout + a minimal Rust program in the guest that WGC-captures two overlapping windows into a fullscreen swapchain on display 2 | 05 | Screenshot of scanout 1 shows both windows complete and unoccluded with alpha; note records max scanout size, per-window copy cost, border/consent behaviour |
| S6 ◐ | Fast resume options: test QMP `stop/cont`, `savevm/loadvm`, migrate-to-file, and guest hibernate with the 3D driver loaded | 02 | Table of what works and time-to-interactive for each; decision recorded |
| S7 | Shared folder options on macOS host with Windows ARM guest: virtiofs, 9p, loopback SMB | 07 | Throughput table and a recommendation |
| S8 ✅ | D3D12-on-MoltenVK feasibility, host only (no VM needed): build vkd3d-proton natively for macOS arm64 against MoltenVK; run its test suite and a few D3D12 demos; list every Vulkan feature/extension vkd3d-proton requires that MoltenVK lacks; repeat with KosmicKrisp | 04 | Findings note with the gap list, pass/fail counts, and a go / patch-MoltenVK / no-go recommendation |

**Gate:** S1, S2 and S4 must pass to continue at all. If S5 fails, seamless
ships on tier 2 (crop) first and the atlas design is revisited. If S3 fails,
fall back to SPICE/CocoaSpice for display and accept the latency.

## M1 — VM runtime core (`SeemlessKit`, `seemlessctl`)

| ID | Work | Acceptance |
|----|------|------------|
| WP1.1 ✅ | `VMConfig` (Codable), paths/layout (02), `qemuArguments()` with snapshot tests | `swift test` passes; argv matches the baseline in 02 |
| WP1.2 ✅ | `QMPClient` actor: connect, capabilities, execute, events; tests against a fake QMP server | Unit tests pass |
| WP1.3 ✅ | `VMProcess`: swtpm + QEMU child management, state machine, log capture, crash detection | `seemlessctl vm start/stop/status` works against the S2 disk |
| WP1.4 ✅ | Disk tooling: create base/overlay, reset, snapshot list/create/restore via `qemu-img` and QMP | `seemlessctl disk ...` commands; tests on temp dirs |
| WP1.5 ◐ | Pause/resume/suspend per S6 outcome (pause/resume done; S6 chose guest hibernate for suspend, which needs the M4 agent to trigger it) | `seemlessctl vm pause/resume/suspend` with timings printed |

## M2 — Image pipeline

| ID | Work | Acceptance |
|----|------|------------|
| WP2.1 ✅ | ISO inspector (UDF/WIM header parsing, validation) | `seemlessctl image inspect <iso>` prints build/arch/editions; rejects x64 ISO |
| WP2.2 ✅ | Payload builder: render unattend templates, recipe → command lists, build `seemless-setup.img` | Golden-file tests of rendered output |
| WP2.3 ✅ | Recipe authoring: enumerate packages/capabilities/features on real media, write `seemless-default.json` and `seemless-gaming.json` with rationale comments in `image/recipes/README.md` | Lists come from real DISM output checked into `image/recipes/inventory/` |
| WP2.4 ◐ | `apply.cmd` full version (runs on real media through first boot with the default recipe, S4/WP2.3) with debloat, driver injection, progress protocol; host-side progress parser | `seemlessctl image build --iso ... --recipe seemless-gaming` produces a booting image unattended |
| WP2.5 ◐ | First-boot script (minimal version: report + shutdown; runtimes, shell config, seal still to do), runtimes install, shell configuration (03), seal + manifest | Image boots to an auto-logged-on, quiet desktop; disk usage and idle RAM reported and compared with G4 |
| WP2.6 | Path B: accept a user-built Tiny11 ISO | Same command works with a Tiny11 Builder output ISO |

## M3 — App shell, display, desktop mode

| ID | Work | Acceptance |
|----|------|------------|
| WP3.0 ◐ | VM manager app (owner request 2026-11-23): SwiftUI, Liquid Glass, macOS 26+. Library sidebar, new VM from ISO (automatic or manual install), settings incl. boot order/TPM/firmware wait, media attach, start/pause/restart/shut down/force off, firmware setup, snapshots, UEFI/TPM reset. Display is QEMU's own window until WP3.2. SwiftPM-built bundle (`scripts/build-app.sh`) until WP3.3 needs an Xcode project | Every action also works from `seemlessctl`; `VMManager` tests pass; screenshots of stopped and running states checked. Not yet clicked through by a person |
| WP3.1 ✅ | Productionise `ui/seemless` patch (protocol in 04), cursor events, resize | Patch applies to pinned QEMU; protocol documented in the patch header |
| WP3.2 | `DisplayRenderer` + `DesktopWindow` in a minimal app target; keyboard and absolute pointer | Desktop mode usable: type in Notepad, resize window changes guest resolution |
| WP3.3 | XPC `SeemlessVMHelper`, entitlements, signing for local runs | App launches the VM through the helper |
| WP3.4 ◐ | Onboarding UI wired to M2 (the New VM sheet already drives `ImageBuilder`; a first-run flow is still to do) | Fresh user account → working desktop mode without Terminal |
| WP3.5 | Audio out, HiDPI scaling, `seemlessctl screenshot`, first `bench` tests (boot, idle, desktop gfx) | Bench JSON produced; T1 targets checked |

## M4 — Guest agent and protocol

| ID | Work | Acceptance |
|----|------|------------|
| WP4.1 ✅ | `proto/seemless.proto`, Swift and Rust codegen, framing, handshake; mock agent | Mock agent ↔ `AgentClient` round-trip tests on macOS |
| WP4.2 | Rust service + session agent skeleton, vioserial transport, named pipe, supervision | `seemlessctl agent info` returns `GuestInfo` from a real VM |
| WP4.3 | Guest tools ISO build + install/update flow | Version bump updates agent in place; survives logoff |
| WP4.4 | System messages: host info (resolution/DPI/work area/theme), time sync, shutdown, session state | Changing Mac appearance flips Windows theme; graceful shutdown works |
| WP4.5 | Clipboard text/RTF/HTML/image both ways with lazy fetch and privacy rules | Manual matrix in `docs/testing/clipboard.md` passes |
| WP4.6 | Windows driver build VM scripts (replaces dependence on UTM's prebuilt drivers) | Drivers built from pinned sources install and pass S2's check |

## M5 — Zen mode (seamless)

Design and build order: docs/05 ("The Zen window", "Readiness and build
order").

| ID | Work | Acceptance |
|----|------|------------|
| WP5.1 | Guest `windows-model`: enumeration, events, classification, `rules.toml`, recorded-dump tests | Dumps from 10 common apps classify as expected (unit tests) |
| WP5.2 | Host `WindowModel` + `WindowBridge` with **tier 2 (crop)** pixels, driven first by the mock agent, then real | Notepad, Explorer and a dialog appear as separate Mac windows; desktop hidden |
| WP5.3 | Input model: pointer focus raise, activation handshake, deactivate, cursor shapes, stuck-key handling | Click-through and wrong-window clicks do not occur in the test script |
| WP5.4 | **Tier 1 (atlas)**: capture crate, allocator, `AtlasFrame`, host sub-rect layers, per-window tier fallback | Two overlapping guest windows separated on the Mac with a Mac window between them, both live |
| WP5.5 | Move/resize/minimise/maximise/close mapping; owned dialogs; transients (menus, tooltips, dropdowns) | Edge-case list in 05 walked and results recorded in `docs/testing/seamless.md` |
| WP5.6 | Launcher (app catalogue, icons, launch), Dock menu, mode switching, agent-lost fallback | Launch any Start-menu app from the Mac launcher |
| WP5.7 | Latency bench + host-driven move (v2) | Move lag under 2 frames (G2) |

## M6 — macOS integration

WP6.1 shared folders (per S7) and document opening · WP6.2 drag and drop
Mac→Windows, then Windows→Mac · WP6.3 notifications · WP6.4 tray icons in the
menu bar extra · WP6.5 stub `.app` bundles + file associations ·
WP6.6 keyboard mapping settings, host IME text input · WP6.7 `OpenOnHost`
default-browser bridge · WP6.8 per-app host processes for separate Dock tiles
(optional, large).

## M7 — Gaming

WP7.1 game-mode presentation + auto-enter · WP7.2 relative mouse with cursor
state detection · WP7.3 XInput controller device + GameController bridge ·
WP7.4 full 3D bench suite and comparison with UTM's published numbers ·
WP7.5 D3D12 host backend (now the whole D3D12 critical path: upstream's
guest driver already speaks D3D12, see WP7b.0): vkd3d-proton built as a
native macOS dylib for `NPT_D3D12_LIBRARY_PATH`, on KosmicKrisp or MoltenVK, wired into the Neptune
host with shared textures/fences (per S8), tested with a host-side D3D12
replay harness · WP7.5b optional D3DMetal opt-in UI and Rosetta render
server · WP7.6 vCPU QoS, idle
CPU, balloon, disk tuning · WP7.7 present-path copy removal and frame pacing
· WP7.8 D3D9 path, Venus-for-Windows evaluation ·
WP7.9 shader cache persistence, games disk.

## M7b — Guest D3D12 driver (only if the trigger in 04 fires)

Trigger reviewed 2026-11-23 (WP7b.0): **not fired**. Upstream ships a D3D12
UMD, so WP7b.1–7 stay dormant.

Runs alongside M6/M7; never blocks them. Prerequisites: S8 "go", WP4.6
(driver build VM), WP7.5 (host backend), D12 resolved. If upstream ships a
usable D3D12 driver, replace this milestone with "integrate upstream's".

| ID | Work | Acceptance |
|----|------|------------|
| WP7b.0 ✅ | Trigger review: state of upstream D3D12 work; contact UTM maintainers; findings note with go/no-go | Note in `docs/spikes/` and decision D3b updated |
| WP7b.1 | Study: D3D12 DDI surface, what the KMD must provide for D3D12 (GPU VA, residency, scheduling), list of DDI entry points grouped by bring-up rung | Design note reviewed against Triton's structure |
| WP7b.2 | Protocol: `d3d12.idl` through the Neptune code generator; host decoder stubs | Generated code builds on both sides; round-trip encode/decode tests pass on the Mac |
| WP7b.3 | Rungs 1–2: device creation, clear + readback | Guest test program output matches host reference |
| WP7b.4 | Rung 3: DXIL triangle off-screen | Image diff vs host reference under threshold |
| WP7b.5 | Rung 4: DXGI swapchain + DWM sharing, D3D11/D3D12 surface interop | Windowed D3D12 sample visible in desktop mode screenshot |
| WP7b.6 | Rungs 5–6: Microsoft samples, vkd3d-proton test suite in guest | Pass counts recorded; failures triaged to driver / protocol / vkd3d-proton / MoltenVK |
| WP7b.7 | Rung 7: Time Spy and first real titles; stability and performance passes | Bench JSON; known-issues list |

## M8 — Release engineering

WP8.1 bundle assembly (prefix → `Contents/Frameworks`, `Helpers`), rpath
fix-ups, universal/arch checks · WP8.2 Developer ID signing, hardened
runtime, notarization · WP8.3 updater (Sparkle) and guest tools versioning ·
WP8.4 driver signing for release (D12) and Secure Boot decision ·
WP8.5 licence compliance bundle (source offers for GPL parts, third-party
notices) · WP8.6 crash reporting and diagnostics export · WP8.7 documentation
site and compatibility guidance.

## Dependency sketch

```
M0 spikes ─► M1 ─► M2 ─┐
                 └─► M3 ─► M4 ─► M5 ─► M6
                              └────► M7
                                        └─► M8
```

M2 and M3 can run in parallel after M1. M6 and M7 can run in parallel after
M5 (M7's game mode needs only M4). M7b, if triggered, runs beside them.

## Session protocol for implementers

1. Read `CLAUDE.md`, `docs/STATUS.md`, then the docs named by the WP.
2. Re-verify any "Provisional" or "verify" statement the WP depends on.
3. Land the feature in `SeemlessKit`/`seemlessctl` or the agent first, with
   tests, then UI.
4. Run the acceptance check. Paste its real output into the session summary.
5. Update `docs/STATUS.md` (what is done, what was learned, what is next) and
   any doc the work proved wrong.
