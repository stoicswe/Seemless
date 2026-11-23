# Status

Updated: 2026-11-23

## Done

- Phase 1 planning documents (`docs/00`–`11`), `CLAUDE.md`.
- Upstream research: UTM 5.0's Neptune/Triton DirectX stack and Tiny11
  Builder 0.2.0 state (see `11-references.md`).

## Not done

- No code, no build scripts, no vendored sources.
- None of the spikes (S1–S7) has been run. Every "Provisional" decision in
  `01-architecture.md` is unproven.
- Nothing in the plan has been tested on hardware.

## Next

1. WP0.1 — repo scaffolding.
2. S1 — build the host graphics stack and QEMU fork.
3. S2 — manual Windows bring-up with Triton drivers; record benchmark scores
   and driver signing facts.
4. S4 — unattended apply-time install.
5. S8 — D3D12-on-MoltenVK feasibility (host only; can run in parallel with
   the others, needs no Windows ISO).

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
