# S6 — Fast resume options

> **Correction (2026-11-24, S6b):** `admfix` was not damaged by hard resets.
> Fast Startup made each shutdown a hibernate, and the resume crashed with
> viogpu3d loaded (bugcheck 0x1E on `ERRIDR_EL1`). Guest hibernate with
> viogpu3d v0.6 does not work yet, even with the QEMU fix. See
> `S6b-hibernate-resume-crash.md`.

Status: **core findings done; one gap** (2026-11-23). Resolves the docs/02
"Suspend to disk" Provisional. Owner-selected after S2.

Host: M3, macOS 27.3, host stack from S1 + the S2 virgl reset-abort fix.
VM: `admfix` (`--root /tmp/slb`, Lean, build 26300, **3D driver loaded** —
viogpu3d/Neptune on DXMT), snapshot `s6-base` taken first.

## What was tested (QMP/HMP on the running VM, 3D driver loaded)

| Mechanism | Result | Detail |
|-----------|--------|--------|
| **QMP `stop` / `cont`** (pause vCPUs) | **Works**, instant | `stop` 0.2 ms → `paused`, `cont` 0.2 ms → `running`. RAM stays in the QEMU process. **Volatile**: lost on `quit`, crash or reboot. |
| **`savevm`** (qcow2 internal snapshot incl. RAM) | **Blocked** | `Error: State blocked by non-migratable device '0000:00:02.0/nvme'`. (virgl and usb-audio block it too — see migrate.) |
| **migrate-to-file** (`migrate -d "exec:cat > …"`) | **Blocked** | `Error: State blocked by non-migratable device '0000:00:02.0/nvme'`. `info migrate` → *Outgoing migration blocked:* `virgl is not yet migratable`, `non-migratable device: 0000:00:03.0/3/usb-audio`, `non-migratable device: 0000:00:02.0/nvme`. |
| **Guest hibernate** (Windows `shutdown /h`) | **Not validated** (see gap) | Device-independent in principle (writes guest RAM → `hiberfil.sys` on the guest disk; no QEMU device-state migration), so it is **not** blocked by the devices above. Resume = boot-from-hiberfil. |

### The gap: hibernate not validated this session

Two blockers, both environmental, not fundamental:

1. **Host is blind to the 3D desktop.** Once the WDDM driver loads, QMP
   `screendump` is black (the composited output is a Neptune/DWM GPU-texture
   scanout QMP can't read — see S2 / the S3 display work). So hibernate could
   not be enabled/triggered/observed by hand with any reliability. Blind
   keystroke injection into the 3D desktop is unreliable.
2. **`admfix` got boot-damaged** by accumulated **hard resets** — the S2
   crash-fix verification (the main session's 10 resets + this session's cold
   boot/reset cycles). Windows tripped **Startup Repair** ("Your device ran
   into a problem and couldn't be repaired"), and restoring `s6-base` still
   booted into it. Windows does not tolerate many back-to-back unclean resets;
   the disk needs a rebuild or a clean reinstall to test hibernate.

Hibernate validation (driver-survives-resume + resume time-to-interactive) is a
clean follow-up on a **fresh VM**, driven via the **S3 display export** (now
done) or the **M4 guest agent**, not blind QMP.

## Decision (resolves docs/02 "Suspend to disk" Provisional)

The Provisional asked whether fast resume is (a) QEMU snapshot, (b) guest
hibernate, or (c) keep paused in RAM. Answer:

- **(a) QEMU snapshot / migrate-to-file — ruled out** with the current device
  model. Three devices are non-migratable: **`virgl`** (the GPU — "not yet
  migratable" upstream; the fundamental blocker the Provisional anticipated),
  **`nvme`** (the system-disk controller), and **`usb-audio`**. `nvme` and
  `usb-audio` are our device choices and could be swapped for migratable
  equivalents (virtio-blk, virtio-sound), but **virgl is the hard blocker** and
  needs upstream virglrenderer migration support before this path is possible.
- **(b) Guest hibernate — the persistent fast-resume path.** It is the only
  option that survives a QEMU quit/reboot and is **independent of the
  non-migratable devices**. Recommended for "suspend to disk". Implement the
  trigger via the guest agent (M4) — or a guest-side `shutdown /h` — rather than
  QEMU migrate. Validate on a fresh VM (above) before depending on it.
- **(c) Paused-in-RAM (`stop`/`cont`) — adopt for transient auto-pause.**
  Instant, but volatile (lost on quit/reboot). This is WP1.5's already-shipped
  `vm pause`/`vm resume`; keep it for the "auto-pause after N idle minutes"
  behaviour in docs/02, not for persistence.

**Net for WP1.5 (`vm suspend`):** suspend-to-disk = **guest hibernate**, not
QEMU migrate. `vm pause`/`resume` stay as the transient in-RAM path.

## Follow-ups

1. Validate guest hibernate on a fresh VM via S3 display / M4 agent: confirm the
   3D driver re-initialises cleanly on resume, and record resume
   time-to-interactive vs a cold boot (~70–80 s observed for cold boot here).
2. If QEMU-snapshot resume is ever wanted: it needs upstream virgl migration
   plus swapping nvme→virtio-blk and usb-audio→virtio-sound. Low priority given
   hibernate covers the need.
3. **Reset-testing caution:** many back-to-back hard resets corrupt the Windows
   boot config (Startup Repair). Use clean guest shutdowns between resets, or a
   throwaway disk, when stress-testing the reset path.

## Artifacts

- `admfix` is currently boot-damaged (Startup Repair); `s6-base` snapshot also
  boots into repair. Needs a rebuild/reinstall before reuse. Flagged to the
  main session.
