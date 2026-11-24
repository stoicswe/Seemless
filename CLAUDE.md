# Seemless — instructions for implementing sessions

Seemless runs a minimal Windows 11 ARM VM on Apple silicon Macs (QEMU + HVF)
and shows each Windows window as a native Mac window. The plan lives in
`docs/`. The repo is at the planning stage: no product code exists yet.

## Start of every session

1. Read `docs/STATUS.md` (current state, next work package).
2. Read `docs/09-roadmap.md` for the work package, then the docs it names.
3. Check `docs/01-architecture.md` → Decision log. "Provisional" decisions
   need their spike done before you build on them.

## Rules

- Never commit, and never offer to. The owner makes all git commits. Leave
  changes in the working tree and summarise what changed.
- One work package per session. Finish with its acceptance check passing and
  paste the real output. Then update `docs/STATUS.md`.
- If reality contradicts a doc, fix the doc in the same change. The docs are
  the handover between sessions.
- Features land in `kit/` (`SeemlessKit` + `seemlessctl`) or the Rust agent
  with tests before any UI.
- The guest is untrusted. Validate everything it sends
  (`docs/06-guest-agent-protocol.md`).
- Pin every external source by commit SHA in `scripts/versions.lock`. Record
  licence and URL in `THIRD_PARTY.md` when adding a dependency.
- Never commit or bundle: Windows ISOs/images/keys, Microsoft tools,
  Apple's `D3DMetal.framework`, Tiny11 Builder code or binaries.
- GPL code (QEMU) stays in `vendor/` and `patches/`; never copy it into
  `kit/`, `app/` or `guest/`.
- Keep QEMU patches small and outside virtio-gpu/Neptune code.
- Graphics bugs: reproduce in UTM with the same pinned versions first when
  possible. Fixes stay local in `patches/` for this project; nothing is sent
  upstream (owner, 2026-11-24).
- No performance change without before/after numbers from `seemlessctl bench`.
- You cannot see the screen: use `seemlessctl screenshot` and agent
  diagnostics to verify visual results, and say so when something was not
  visually verified.

## Layout (target; see docs/01)

`app/` Xcode app + helper · `kit/` Swift package + CLI · `guest/agent/` Rust
· `guest/tools/` tools ISO · `image/` unattend, recipes, WinPE script ·
`proto/` protobuf · `patches/` · `vendor/` submodules · `scripts/` ·
`build/` (gitignored) · `docs/`.

## Commands

- Tool check: `scripts/bootstrap.sh` (`--strict` makes later-milestone tools fatal)
- Everything that runs without a VM (also what CI runs): `scripts/check.sh`
- Swift: `swift build --package-path kit`, `swift test --package-path kit`
- CLI: `kit/.build/debug/seemlessctl --help`
- Rust: always use rustup's cargo, `~/.cargo/bin/cargo`. On this Mac Homebrew's
  `cargo` comes first on PATH and ignores `guest/agent/rust-toolchain.toml`
  (pinned 1.99.1).
- Agent logic tests (macOS): `~/.cargo/bin/cargo test --manifest-path guest/agent/Cargo.toml -p windows-model`
- Agent Windows build (from M4; needs the target and cargo-xwin, see bootstrap):
  `~/.cargo/bin/cargo xwin build --manifest-path guest/agent/Cargo.toml --target aarch64-pc-windows-msvc --release`
- Host stack (S1): `scripts/build-deps.sh fetch`, then `scripts/build-deps.sh all`
  (or named components; `--force <name>` to rebuild). Output in `build/prefix`,
  logs in `build/logs/`.
- VM (M1): `seemlessctl vm create|show|run|status|pause|resume|stop|delete`,
  `seemlessctl disk info|snapshot|reset|resize`, `seemlessctl stack`. Use
  `--root <dir>` for a throwaway storage root in experiments.
- VM settings: `seemlessctl vm set` (cpus, memory, disk grow, boot order, TPM,
  firmware wait, forwards), `vm media attach|detach|list`, `vm restart`,
  `vm firmware reset-vars|reset-tpm`, `vm screendump --out x.png` (see the
  guest screen yourself), `vm run --firmware-setup|--cd-prompt`,
  `vm open <installer.exe|.msi>` (Open in Seemless; VM must be running).
- App (WP3.0): `scripts/build-app.sh [--open]` → `build/app/Seemless.app`.
  `SEEMLESS_ROOT=<dir>` for a throwaway root; `SEEMLESS_OPEN=new-vm`
  (`-automatic`, `-about`) opens the New VM sheet for screenshots. Screenshot its window with
  `screencapture -x -o -l <windowid>` (window id via CGWindowListCopyWindowInfo).
- Release app (P1, WP8.1/8.2/8.5; runbook `docs/release.md`):
  `scripts/package-release.sh` → `build/release/` (self-contained
  `Seemless.app`, dmg, zip; audit, ad-hoc signing without
  `SEEMLESS_SIGN_IDENTITY`, notarization with `SEEMLESS_NOTARY_PROFILE`).
  `scripts/release/source-archive.sh` writes the source offer. Every
  library in the app is built from pinned source (`build-deps.sh` builds
  GLib, OpenSSL & co. hermetically, without Homebrew's bottles); the
  bundler refuses Homebrew libraries.
  The app and `seemlessctl` inside a bundle use the bundled stack
  (`HostStack.locate()`); test relocated bundles under `sandbox-exec`
  denying `build/prefix` and `/opt/homebrew` rather than renaming the
  prefix other sessions use.
- Windows image (M2): `seemlessctl image inspect <iso>`, `image build --iso`,
  `image payload --out`, `image result`. Runbook: `docs/testing/first-iso.md`.
- Agent protocol (M4): schema `proto/seemless.proto`; after editing it run
  `scripts/gen-proto.sh` (Swift; `--check` in CI). Rust regenerates on build.
  `seemlessctl mock-agent --socket /tmp/x.sock [--script proto/mock/notepad.json]`
  serves a fake agent; `seemlessctl agent hello|info --socket <path>` (or
  `--name <vm>`) talks to it. Socket paths must be under 104 bytes: use
  `/tmp`, not the scratchpad.
- Zen mode (Z1 preview, docs/05): needs a VM run with `--export-display`.
  `SEEMLESS_OPEN=zen:<vm>` enters it at launch,
  `SEEMLESS_ZEN_AGENT=<mock-agent socket>` drives windows from a script
  until the Windows agent exists, and `SEEMLESS_ZEN_SCALE` sets points per
  guest pixel. `SEEMLESS_OPEN=display:<vm>` runs Show Display at launch
  (the desktop window for an exported display); `SEEMLESS_DISPLAY_TYPE='text\n'`
  then types into it through the window (lowercase, digits, space, `\n`;
  synthetic CGEvents need a permission this Mac lacks), and
  `SEEMLESS_DISPLAY_SCALE` sets points per guest pixel.
  `SEEMLESS_OPEN=select:<vm>` only selects a VM (for
  screenshots of the running layout). `SEEMLESS_ZEN_STATS=1` logs hit
  tests, `SetWindowRect`s and frames every 10 s, and each click's guest pixel.
  Real Windows windows before the agent exists: run
  `proto/mock/zen-guest-helper.ps1` in the guest (needs the guest's network)
  and `mock-agent --script proto/mock/notepad-live.json`. Test list and
  results: `docs/testing/seamless.md`.
- Desktop mode and first run (P2, `docs/testing/desktop-mode.md`): the app
  starts VMs exported and opens its desktop window. `SEEMLESS_OPEN=welcome`
  shows the first-run flow; `SEEMLESS_FIRSTRUN_ISO=<iso>`,
  `SEEMLESS_FIRSTRUN_PROFILE=lean|leanXbox|fat`, `SEEMLESS_FIRSTRUN_GO=1`
  run it without clicks. Desktop window switches: `SEEMLESS_DISPLAY_RESIZE=WxH`
  (points), `_FULLSCREEN=1`, `_KEYS=ctrlAltDelete` (any `GuestKeyCombo`),
  `_TYPE` now takes `{cmd}`, `{cmd+a}`, `{shift+h}`, `{ret}`, `{wait}`;
  `_LOG=1` logs size requests. Guest drivers for installs:
  `$SEEMLESS_GUEST_DRIVERS`, the bundle's `Resources/guest-drivers`, or
  `build/guest-drivers` (viogpu3d + netkvm + vioserial copied from
  `build/s3/drivers` and `build/wp42/drivers`). Per-VM display settings:
  `vms/<name>/display.json`.
- D3D12 backend (WP7.5): `scripts/build-deps.sh moltenvk vkd3d`, then
  `scripts/d3d12-host/build.sh` and `build/wp75/bin/d3d12hosttest
  build/prefix/lib/libvkd3d-proton-d3d12.dylib` (ladder rungs 1–3 on the
  host); `guest/tools/d3d12test/build.sh` builds the guest test exe.
  Runbook: `docs/spikes/WP7.5-d3d12-host-backend.md`.
- Tests: `swift test --package-path kit` (integration tests boot real QEMU to
  firmware; they skip themselves if `build/prefix` is missing).
- Smoke-boot the stack: `scripts/smoke-qemu.sh` (headless) or `--window`
  (GL device; opens a window). Proves config and firmware boot only: the GPU
  renderer starts on the first guest driver command, so it needs Windows (S2).
