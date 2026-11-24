# guest/tools

Builds `seemless-tools.iso` (docs/06 "Guest tools ISO", WP4.3):

- `build-agent.sh`: the agent (cargo-xwin) → `build/guest-tools/agent/`.
- `build.sh [--skip-agent-build] [--drivers <dir>]`: runs it, then stages
  `build/guest-tools/iso/` and writes `build/guest-tools/seemless-tools.iso`.
- `install.cmd`: the ISO's top-level installer; `agent/install.cmd` and
  `agent/uninstall.cmd`: the service's.

Install in new VMs: automatic (`image build`). Update a running VM:
`seemlessctl tools update --name <vm>`.

`d3d12test/`: WP7.5's guest D3D12 ladder test (`build.sh` → `build/wp75/guest/d3d12guesttest.exe`, built on the Mac without Microsoft tools). A test tool, not part of the tools ISO.
