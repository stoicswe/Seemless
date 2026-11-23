# 00 — Overview: vision, scope, targets

## What Seemless is

Seemless is a macOS app (Apple silicon only) that runs a minimal Windows 11 ARM
virtual machine and presents Windows applications as if they were Mac apps:

1. **A purpose-built Windows runtime.** A QEMU-based VM (Hypervisor.framework
   acceleration) with a fixed, opinionated device model. Users never see VM
   settings; there is one runtime and it is tuned for one guest.
2. **A minimal Windows 11 ARM image.** Built on the user's Mac from the user's
   own Microsoft ISO, debloated following the Tiny11 removal set, with our
   drivers and guest agent pre-installed. No Windows bits are redistributed.
3. **GPU-accelerated DirectX.** Direct3D 11 (and later 12) calls are forwarded
   from a real WDDM driver in the guest to a Direct3D-on-Metal implementation
   on the host. We build on UTM's open-source Neptune/Triton stack rather than
   inventing one (see [04-graphics.md](04-graphics.md)).
4. **Seamless mode.** The Windows desktop is hidden. Each Windows top-level
   window becomes its own `NSWindow`, with Dock icons, Mission Control, Cmd-Tab,
   clipboard, drag and drop, file associations and notifications bridged.
5. **A desktop mode and a game mode** for when a single surface is the right
   answer (setup, troubleshooting, exclusive-fullscreen games).

## Who it is for

- Mac users who need specific Windows apps and want them next to Mac apps.
- Mac users who want to play Windows games that have no Mac port and do not
  need kernel anti-cheat.

## Goals (in priority order)

| # | Goal | Measured by |
|---|------|-------------|
| G1 | One-click setup: ISO in, usable Windows app windows out | Fresh Mac to first Windows app window in under 25 minutes, zero Windows Setup screens |
| G2 | Seamless windows feel native | Window move/resize latency under 2 frames; correct z-order with Mac windows; no visible Windows desktop |
| G3 | Usable gaming performance | See performance targets below |
| G4 | Small footprint | Installed guest under 12 GB on disk; idle guest under 2.5 GB RAM and under 3% of one host core |
| G5 | Fast start | Resume from suspended state to interactive in under 3 s; cold boot under 15 s |

## Performance targets (honest version)

"High-end gaming performance" needs a concrete definition, because a VM pays
three taxes that a native PC does not:

1. **CPU translation.** Almost all Windows games are x64. In an ARM guest they
   run through Microsoft's Prism emulator. Expect roughly 50–80% of native ARM
   speed on CPU-bound code. We do not control this.
2. **Graphics translation.** D3D → (wire) → D3D-on-Metal → Metal. UTM's
   published results show this path can beat DXVK-over-Venus, but it is not
   native D3D.
3. **Virtualization overhead.** Small for CPU under HVF, larger for I/O.

Targets for an M3 Pro–class machine, 1440p, medium settings:

| Tier | Target | Example workload |
|------|--------|------------------|
| T1 (M3 gate) | D3D11 desktop composition at display refresh, 3DMark Fire Strike completes | Windows desktop, Office, browsers |
| T2 (M7 gate) | 60 fps in 2015–2020 era D3D11 titles | Civilization VI, FFXIV benchmark |
| T3 (stretch) | Playable D3D12 titles via vkd3d-proton on MoltenVK (bundled, open source) | Depends on MoltenVK feature coverage (spike S8) and on a guest D3D12 driver |

Explicit non-targets: parity with native Windows hardware; parity with
CrossOver/Wine for titles where Wine works (Wine skips the VM tax entirely).
Our advantage is compatibility and integration: a real Windows kernel, real
installers, real launchers.

## Non-goals

- Intel Macs. x86 Windows guests. Windows 10. Linux/macOS guests.
- Kernel-level anti-cheat titles (Vanguard, EAC/BattlEye in kernel mode,
  etc.). They detect or refuse VMs and/or lack ARM64 drivers. Do not promise
  these and do not attempt to hide the hypervisor.
- A general-purpose VM manager. No device pickers, no arbitrary guests. UTM
  already is that.
- Redistributing Windows, Microsoft tools, or Apple's D3DMetal.
- Mac App Store distribution (see [10-risks-licensing.md](10-risks-licensing.md)).

## The three presentation modes

| Mode | What the user sees | When |
|------|--------------------|------|
| **Seamless** (default) | One `NSWindow` per Windows window; no desktop, no taskbar | Day-to-day apps, windowed games |
| **Desktop** | One Mac window (or fullscreen Space) showing the whole Windows desktop | First boot, troubleshooting, apps that misbehave in seamless |
| **Game** | Fullscreen, low-latency, relative mouse, the guest's primary display scanned out directly | Exclusive/borderless fullscreen games; entered automatically |

## Glossary

| Term | Meaning |
|------|---------|
| HVF | Hypervisor.framework, Apple's hardware virtualization API; QEMU's `-accel hvf` |
| QMP | QEMU Machine Protocol, JSON control socket |
| WDDM | Windows Display Driver Model. KMD = kernel-mode driver, UMD = user-mode driver, DDI = the driver interface D3D calls into |
| DWM | Desktop Window Manager, the Windows compositor |
| Neptune | UTM's virglrenderer protocol that carries Direct3D API calls over virtio-gpu |
| Triton | UTM's Windows D3D11 UMD that turns DDI calls back into D3D API calls and feeds Neptune |
| Venus | virglrenderer's Vulkan-over-virtio-gpu protocol |
| DXMT | Open-source D3D11-on-Metal implementation |
| MoltenVK | Vulkan-on-Metal translation layer (Apache-2.0). Our planned host Vulkan driver for D3D12 and for Venus |
| vkd3d-proton | D3D12-on-Vulkan implementation (LGPL-2.1). Runs on the host, on top of MoltenVK |
| D3DMetal | Apple's D3D11/12-on-Metal framework from the Game Porting Toolkit (x86_64 only, restrictive licence). Optional, user-supplied alternative only |
| Prism | Windows 11 on ARM's x86/x64 emulator |
| WGC | Windows.Graphics.Capture, per-window GPU capture API |
| Agent | Our Windows-side service + per-session helper (`seemless-agent`) |
| Golden image | The finished, sysprepped-equivalent guest disk produced by the image pipeline |
| Atlas | A second guest display onto which the agent blits every captured window, read by the host |
