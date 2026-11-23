# Seemless
A parallel computing environment.

Seemless runs a minimal Windows 11 ARM virtual machine on Apple silicon Macs
and presents each Windows application window as a native Mac window, with
GPU-accelerated DirectX for games.

**Status: planning.** No product code yet. See [docs/STATUS.md](docs/STATUS.md).

## How it works (planned)

- **Runtime:** QEMU with Hypervisor.framework, one fixed configuration, based
  on UTM's QEMU fork.
- **Windows image:** built on your Mac from your own Microsoft ARM64 ISO,
  trimmed following the Tiny11 removal set, with drivers and a guest agent
  pre-installed. No Windows components are redistributed.
- **Graphics:** Direct3D calls forwarded from a real WDDM driver in the guest
  to the host (UTM's Neptune/Triton stack). Direct3D 11 runs on DXMT;
  Direct3D 12 is planned through vkd3d-proton on MoltenVK.
- **Seamless mode:** a guest agent tracks every Windows window and captures
  each one separately; the Mac app shows them as individual windows with
  clipboard, files, notifications and Dock integration.

## Documentation

| Doc | Contents |
|-----|----------|
| [00 Overview](docs/00-overview.md) | Vision, goals, performance targets, non-goals, glossary |
| [01 Architecture](docs/01-architecture.md) | Components, processes, repo layout, decision log |
| [02 VM runtime](docs/02-vm-runtime.md) | QEMU build, command line, storage, lifecycle, patches |
| [03 Windows image](docs/03-windows-image.md) | Tiny11-style image pipeline, recipes, unattended install |
| [04 Graphics](docs/04-graphics.md) | Neptune/Triton stack, display export, driver signing |
| [05 Seamless mode](docs/05-seamless-mode.md) | Per-window capture, geometry, input, focus |
| [06 Guest agent and protocol](docs/06-guest-agent-protocol.md) | Agent processes, message catalogue, validation |
| [07 Host app and integration](docs/07-host-app-integration.md) | App structure, keyboard, clipboard, files, audio, devices |
| [08 Performance and gaming](docs/08-performance-gaming.md) | Benchmarks, tuning, game mode |
| [09 Roadmap](docs/09-roadmap.md) | Milestones, spikes, session-sized work packages |
| [10 Risks and licensing](docs/10-risks-licensing.md) | Risk register, open questions, licence constraints |
| [11 References](docs/11-references.md) | Sources and what was verified |

Implementing sessions start with [CLAUDE.md](CLAUDE.md).

## Limits to know up front

- Apple silicon Macs running macOS 26 or later; Windows 11 ARM64 only.
- x64 games run through Windows' own emulator, so CPU-heavy titles run below
  native speed.
- Games that need kernel anti-cheat will not work.
- You need your own Windows ISO and licence.
