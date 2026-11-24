# S3 display spike (throwaway)

Superseded by WP3.1: the backend is now `patches/qemu/0001-ui-seemless-display-backend.patch`
(protocol v1, different message layout) and the client is `SeemlessKit.DisplayClient`.
This viewer speaks the spike's v0 protocol and no longer works with `build/prefix`.

Findings: `docs/spikes/S3-display-export.md`. QEMU side was
`patches/qemu/spike-S3-ui-seemless.patch` (removed), built by hand into `build/s3/`
(clone `build/src/qemu` at the pinned SHA, apply, configure like
`scripts/build-deps.sh` with `--prefix=build/s3/prefix`, `make qemu-system-aarch64`).

- `swift build -c release`
- `run.sh seemless|cocoa <workdir> [disk efi_vars tpm_dir]` — start the patched QEMU
- `view.sh <workdir> [--arrival] [--drawables N]` — start `S3Viewer`; commands via `<workdir>/cmd`
- `measure.sh <label> cocoa|seemless [viewer args]` — one firmware latency run
- `evidence/` — window captures and the latency results quoted in the note

Workdir paths must be short (QMP unix socket path < 104 bytes).
