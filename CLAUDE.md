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
- Graphics bugs: reproduce in UTM with the same pinned versions first; fix
  upstream if it reproduces there.
- No performance change without before/after numbers from `seemlessctl bench`.
- You cannot see the screen: use `seemlessctl screenshot` and agent
  diagnostics to verify visual results, and say so when something was not
  visually verified.

## Layout (target; see docs/01)

`app/` Xcode app + helper · `kit/` Swift package + CLI · `guest/agent/` Rust
· `guest/tools/` tools ISO · `image/` unattend, recipes, WinPE script ·
`proto/` protobuf · `patches/` · `vendor/` submodules · `scripts/` ·
`build/` (gitignored) · `docs/`.

## Commands (fill in as they come into existence)

- Bootstrap: `scripts/bootstrap.sh`
- Host deps + QEMU: `scripts/build-deps.sh`, `scripts/build-qemu.sh`
- Swift tests: `swift test --package-path kit`
- Agent build: `cargo xwin build --manifest-path guest/agent/Cargo.toml --target aarch64-pc-windows-msvc --release`
- Agent logic tests (run on macOS): `cargo test --manifest-path guest/agent/Cargo.toml -p windows-model`
