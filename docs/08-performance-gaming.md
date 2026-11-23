# 08 — Performance and gaming

Performance work is measurement-led. No optimisation lands without a number
from the benchmark suite before and after.

## Benchmark suite (`seemlessctl bench`)

Build this in M3 and extend it; results are appended to
`build/bench/<date>-<git-sha>.json` and compared against the last run.

| Area | Test | Metric |
|------|------|--------|
| Boot | Cold start to agent `Hello` | seconds |
| Resume | Paused → first frame; suspended → first frame | ms |
| Idle | Host CPU % and RSS of QEMU + render servers, guest idle 5 min | %, MiB |
| CPU | Geekbench-class native ARM64 run in guest vs macOS native; an x64 workload under Prism (7-Zip benchmark x64 vs ARM64 build) | score ratio |
| Disk | `diskspd` sequential and 4K random on `C:` | MB/s, IOPS |
| Shared folder | Copy 1 GB single file and 10k small files both ways | s |
| Network | iperf3 guest↔host | Gbit/s |
| Desktop gfx | DWM frame pacing while dragging a window at 4K (PresentMon in guest) | frame time p50/p99 |
| Seamless | End-to-end latency: host mouse-down → pixel change in the `NSWindow` (photodiode-free method: agent test app flips colour on click; host timestamps input and first changed atlas frame) | ms |
| 3D | 3DMark Fire Strike (free, D3D11), Unigine Heaven, FFXIV Dawntrail benchmark, Civilization VI benchmark | score / fps. These are the titles UTM published, so we can compare against their numbers |
| Audio | Loopback latency | ms |

Every 3D run records: backend (DXMT / vkd3d-proton+MoltenVK / D3DMetal), driver versions, resolution,
vCPUs, host model, power source.

## CPU

- vCPU count defaults to the number of performance cores (cap 8). Windows
  schedules poorly when vCPUs are backed by a mix of P and E cores, because
  it cannot see the difference.
- vCPU threads get `QOS_CLASS_USER_INTERACTIVE` so macOS prefers P-cores
  (patch in 02). Verify with `powermetrics` that vCPU threads stay on the
  P cluster under load.
- Idle: make sure WFI exits park the vCPU thread instead of spinning. Measure
  idle host CPU; under 3% of a core is the goal (G4).
- Timers: Windows on ARM uses the generic timer; check for clock drift after
  pause/resume and Mac sleep. The agent resyncs wall time; games that use QPC
  deltas should see a jump no larger than the pause (decide whether to hide
  paused time by offsetting the virtual counter; QEMU's default behaviour on
  HVF must be tested).
- Prism: we cannot tune it, but we can avoid harming it. Keep WOW64 and all
  emulation components; keep Windows updated (Prism gained AVX/AVX2 support
  through updates). Per-app emulation settings ("Windows on Arm" compatibility
  tab) can be surfaced later.
- Game Mode on macOS engages for fullscreen apps declared as games:
  set `LSApplicationCategoryType` to a games category and
  `LSSupportsGameMode` on the app (or on a dedicated game-mode host process)
  and verify it actually prioritises our helper/QEMU child processes. If it
  only applies to the declaring process, investigate making the fullscreen
  presenter the process that matters. **Open question.**

## Memory

- Default RAM 8 GiB (02). Unified memory means guest RAM and GPU memory
  compete; `hostmem=8G` on the GPU device is address space for blob
  resources, not a reservation. Watch real usage.
- Do not preallocate guest RAM. Add virtio-balloon + agent-driven working-set
  trimming in M7. Free page reporting if the Windows balloon driver supports
  it.
- Guest: page file fixed small (2–4 GiB) to avoid qcow2 growth; memory
  compression left on; SysMain (Superfetch) disabled.

## Disk

- NVMe emulation with one I/O thread to start. Compare with `virtio-blk-pci`
  + iothread + viostor in M7; switch only if the win is clear, because NVMe's
  inbox driver is what keeps WinPE simple (03) (a virtio disk can still be
  the *runtime* disk while NVMe is used for install).
- qcow2 with `discard=unmap`; guest TRIM enabled so deleted files shrink the
  overlay. `cache=writethrough` vs `none`/`unsafe`: measure, but never ship a
  mode that can corrupt NTFS on host crash.
- Large games: recommend installing to a second qcow2 "Games" disk that is
  not part of the reset overlay, or to a raw sparse file for speed. Shared
  folders are too slow for game installs.
- Defender real-time scanning is a major I/O tax for game loading; offer
  exclusions for game library folders.

## Graphics

- Backend: DXMT for D3D11, vkd3d-proton on MoltenVK for D3D12 (04). D3DMetal
  is an optional user-supplied alternative; benchmark it against the bundled
  backends when available so we know what the gap is.
- Remove copies on the present path in this order: (1) scanout → IOSurface
  blit in QEMU, (2) IOSurface → layer in the app (use the IOSurface as layer
  contents directly in game mode: `CALayer.contents = IOSurface` or
  `CAMetalLayer` blit; pick by measurement), (3) atlas copy in the guest
  (unavoidable in seamless; bypassed in game mode).
- Frame pacing: the guest should see a vblank that matches the host display.
  Find out how the KMD generates vsync (timer vs host signal). For ProMotion,
  target the host refresh rate in game mode; expose a frame cap.
- Shader compilation stutter: DXMT and MoltenVK (SPIR-V → MSL → Metal
  pipeline state) compile Metal shaders on first
  use. Persist their shader caches per game across runs (cache directory in
  Application Support, keyed by executable hash).
- Ring-buffer waits: Neptune/Venus use a shared ring with host polling
  threads; check idle CPU cost of render servers when a game is paused or the
  desktop is static.

## Game mode

Entered automatically (05) or by shortcut.

| Aspect | Behaviour |
|--------|-----------|
| Presentation | Native fullscreen Space (or borderless at screen level if lower latency measures better), scanout 0 presented directly; atlas captures stopped |
| Resolution | Guest display set to the Mac display's native pixels or a chosen lower render resolution with host-side scaling (MetalFX spatial upscaling is a later option) |
| Mouse | Relative mode: `CGAssociateMouseAndMouseCursorPosition(false)`, hide cursor, feed raw deltas (no acceleration: use `GCMouse` or `NSEvent` with `mouseCoalescingEnabled = false`) to a relative pointer device. Engage when the agent reports `CursorState{visible:false}` or `clipped:true`; release when the cursor is shown again (menus) so absolute positioning works |
| Keyboard | Raw: no remapping, all system shortcuts except the release chord disabled where the OS allows (`NSApplication.PresentationOptions`) |
| Controllers | XInput emulation (07) |
| Audio | Smaller buffer size if stable |
| Overlay | Optional HUD (frame time, backend, render resolution) drawn host-side |
| Exit | Release chord, Cmd-Tab, or the game leaving fullscreen |

## Compatibility expectations to communicate in-product

- Works best: D3D11 single-player and co-op titles, older D3D9/10 titles
  (once the D3D9 path is verified), launchers (Steam, Epic, GOG, Battle.net).
- Limited: D3D12-only titles (need the guest D3D12 driver and whatever
  vkd3d-proton features MoltenVK can back; see 04), Vulkan-only titles
  (need Venus for Windows), OpenGL titles (software until later).
- Does not work: kernel anti-cheat titles, games requiring AVX-512, titles
  with ARM-incompatible DRM drivers.
- Link to UTM's games database for community status, since the graphics stack
  is shared; consider contributing reports upstream.

## Perf investigation playbook (for implementing sessions)

1. Reproduce with `seemlessctl bench <test>`; save the JSON.
2. Classify: guest CPU-bound (Task Manager/`typeperf` via agent), host
   render-server-bound (`sample`, Instruments Metal System Trace), or
   transport-bound (QEMU main loop / ring waits).
3. Check the same workload in UTM with the same pinned graphics versions. If
   UTM is equally slow, the problem is upstream of our code.
4. Change one thing; re-run; record both numbers in the commit message.
