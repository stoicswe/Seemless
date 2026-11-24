# S6b — Why VMs stopped booting after a clean shutdown

Status: **cause found; workaround in the image pipeline; hibernate with
viogpu3d still broken** (2026-11-24). Follow-up to S6 (fast resume) and to
WP3.1's "`wp31` broke on its third boot" (end of S3's note).

Host: M3, macOS 27.3, host stack from S1 (`build/prefix`, UTM QEMU fork
`8ab298b` + `patches/qemu/0001`). Guests: Windows 11 ARM64 build 26300,
Lean, UTM viogpu3d v0.6.

## Answer

1. Windows' **Fast Startup** is on by default. Every "shut down" is a
   hybrid shutdown, which is a hibernate: `vm stop` presses the ACPI power
   button. The next start is a **resume from `hiberfil.sys`**.
2. With **viogpu3d** loaded, the resumed guest writes through a mapping into
   virtio-gpu's host-visible blob window (PCI BAR in high MMIO). That mapping
   no longer exists on the fresh device. The store has no syndrome
   (`isv=0`), so QEMU's HVF code injects a **synchronous external abort**.
3. Windows' abort handler reads the RAS register **`ERRIDR_EL1`**
   (`MRS x8, S3_0_C5_C3_0`, encoding `0xD5385308`). QEMU's HVF backend has no
   handler for it and injects UNDEF. Windows bugchecks **0x1E**
   `KMODE_EXCEPTION_NOT_HANDLED`, `C000001D` (illegal instruction), always at
   the same `nt` offset `…17bc`.
4. After the bugcheck's reset, the firmware sometimes boots normally (and
   the user sees nothing wrong). Sometimes it sits in firmware with only vCPU 0
   running at PC `0x23f6b0924` until QEMU is killed. The boot after that kill
   goes to **Startup Repair** ("couldn't be repaired": it finds no root
   cause).

Neither the TPM nor an EFI variable is involved. The TPM state file was never
written after creation. The resolution change is not needed: the
first crash came before any resize. Hard resets did not cause it either:
`admfix` has the same two dumps.

## Evidence

### `wp31`'s disk (read-only copy, mounted with macOS' read-only NTFS)

- `hiberfil.sys` was 8.6 GB with signature `WAKE` (a resume was attempted),
  last written at the end of boot 2.
- `C:\Windows\MEMORY.DMP` and `Minidump\112426-9234-01.dmp` hold a kernel
  dump (`PAGEDU64`): bugcheck `0x1E`, params `C000001D`,
  `fffff8024e8a17bc`, `80000144`, `D5385308`; 14:45:17Z, uptime 94 s.
- Startup Repair extracted a second dump from `pagefile.sys`
  (`Srt\setupmem.dmp`): the same bugcheck and `nt` offset; 14:52:50Z,
  uptime 442 s.
- Uptime runs on across a hibernate. So the 94 s crash is the resume of
  boot 1's image, at the start of boot 2. Boot 2's QEMU log shows two
  virtio-gpu initialisations in one process: the resume, then the cold boot
  after the crash. The 442 s crash is the resume of boot 2's image, which
  was boot 3, the one that "hung".
- `SrtTrail.txt`: every test passed, root causes 0. `bcdinfo.txt` has the
  resume object pointing at `\hiberfil.sys`.

### `admfix` (`/tmp/slb`, read-only copies of the current disk and of `s6-base`)

- Two dumps with the same bugcheck, params and `nt` offset `…17bc`:
  2026-11-24 02:56Z (uptime 797 s) and 04:04Z (uptime 2642 s).
- `hiberfil.sys` is `WAKE`.
- `s6-base` was taken after the damage and is byte-for-byte the same story,
  which is why restoring it "still booted into repair".

### Reproduction (throwaway overlays in `build/bootfix/`, never the originals)

QEMU ran with `-trace hvf_unhandled_sysreg_read,hvf_psci_call` (and
`hvf_data_abort` once), through a wrapper prefix
(`SEEMLESS_PREFIX=build/bootfix/prefix-trace`).

| Run | VM | QEMU | What happened |
|-----|----|------|---------------|
| 1 | `r1` = overlay of `wp31` + copies of its vars/TPM | stock | cold boot to the 3D desktop (screenshot). `vm stop` took 6.5 s, PSCI `SYSTEM_OFF`; `hiberfil.sys` became `HIBR` (a hybrid shutdown). State saved. |
| 2 | `r1`, from the saved `HIBR` state | stock | resume: `CPU_ON`×3, virtio-gpu init, then `unhandled sysreg read at pc=0xfffff800dcb617bc (op0=3 op1=0 crn=5 crm=3 op2=0)`, then PSCI `SYSTEM_RESET`. Firmware screen, vCPU 0 at **PC `0x23f6b0924`** (the same PC `wp31` hung at), CPUs 1–3 off. A key press and a QMP `system_reset` did not help. |
| 5 | `r1`, same saved state | stock, + `hvf_data_abort` | `data abort: [pc=0xfffff800e282d80c va=0x000001aba6faf804 pa=0x000000810a2db804 isv=0 iswrite=1]`, then 3 lines later the same `ERRIDR_EL1` read, then reset. This time the post-crash cold boot went through. |
| — | `n1` = overlay of S2's `s2` (**no 3D driver**) | stock | cold boot, `vm stop` (hybrid), start: **resume worked**, desktop with the right clock, no unhandled sysreg. |
| 3, 4 | `r1`, same saved state | **patched** (0002 below) | resume gets through: no unhandled sysreg, no reset, the kernel is alive (idle-loop and user-mode PCs for 2+ min), Neptune contexts created. But **no scanout** comes back: 800×600 black 2D frame, and `display size` has no effect. The power button gave no `SYSTEM_OFF` in 90/180 s. A new dump in `pagefile.sys`: bugcheck **0xC** `MAXIMUM_WAIT_OBJECTS_EXCEEDED` at 15:33Z, during that shutdown. |
| — | `a1` = overlay of `admfix` | stock | cold boot straight to the 3D desktop (no repair). `HiberbootEnabled` set to 0 in the guest (`reg query` shows `0x0`); `vm stop` is a full shutdown (`hiberfil.sys` not rewritten, PSCI `SYSTEM_OFF`). Then 2 × (start, 70 s, screenshot, `vm stop`): each a cold boot to the 3D desktop (1024×768 `metal`), 0 unhandled sysregs, 0 resets, `SYSTEM_OFF`. |

Key log lines: `build/bootfix/r1-run5-key-lines.txt` (the full 1.2 M-line log
is `r1-run5-qemu.log.gz`); screenshots `build/bootfix/shot-*.png` (not
committed: Microsoft wallpaper). Only the screenshots listed above were looked
at.

## Fixes

1. **Image pipeline (workaround, the fix that matters now).**
   `image/winpe/firstboot.cmd` sets
   `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 0`
   for every recipe (stock included). A failure is the build result:
   `ERROR faststartup …` instead of `FIRSTBOOT_OK`. Hibernation itself
   stays on, because S6 needs it. Shutdown is then a real shutdown, which a
   VM needs anyway: a Fast Startup image would also break after `vm set`
   changes CPUs, memory or devices. Test:
   `SetupPayloadRenderTests.firstbootDisablesFastStartup`. `scripts/check.sh`
   passes (144 Swift tests). Not run through a fresh `image build`: that needs
   the owner at first start. The same `reg add` was checked by hand on `a1`.
2. **QEMU robustness: `patches/qemu/0002-hvf-arm-ras-error-records-raz-wi.patch`.**
   `ERRIDR_EL1`, `ERRSELR_EL1` and `ERX*` read as zero and ignore writes
   under HVF, as KVM does. `ERRIDR_EL1 = 0` ("no error records") is what
   TCG's `minimal_ras_reginfo` already gives. It is small, outside
   virtio-gpu, and worth sending upstream. It does **not** make resume work
   with viogpu3d (runs 3–4): it only turns the illegal-instruction bugcheck
   into the real problem.
   **Not installed:** it is applied in `build/src/qemu` and built, but
   `build/prefix` was not reinstalled, because another session had a VM
   running from it. Run `scripts/build-deps.sh --force qemu` when no VM is
   running.

Existing VMs (`wp31`, `admfix`, the owner's) keep Fast Startup until it is
turned off in the guest (an elevated
`reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f`,
or `powercfg /h off`). Until then, shut them down with
`shutdown /s /t 0` in the guest rather than `vm stop`. Their copies here
cold-booted to the desktop on the first start from a fresh QEMU process.
So `wp31` and `admfix` themselves are most likely recoverable by just
starting them again. That was not done on the originals.

## What this means for S6 (hibernate)

It explains S6's worry, and the answer is bad for now. **Hibernate with
viogpu3d v0.6 does not work:**

- On stock QEMU the resume bugchecks (above).
- On patched QEMU the OS resumes, but the display is never set up again and
  the next shutdown bugchecks 0xC.
- Without the 3D driver, hibernate resume works on stock QEMU (`n1`).

So suspend-to-disk is blocked on the guest driver: viogpu3d has to drop or
re-create its blob mappings and scanouts across a D3→D0 power-up. This is a
graphics bug, so by CLAUDE.md it should first be reproduced in UTM with the
same versions (UTM not installed here), then reported to UTM. QMP
`stop`/`cont` (S6 option c) is unaffected.

## Still unknown

- Which code in the guest makes the abort: it is a user-mode VA (DWM or the
  UMD writing into a mapped blob), PA `0x810a2db804` in the high PCI MMIO
  window. The mapping to the virtio-gpu hostmem BAR was inferred from the
  address range, not checked with `info mtree`.
- The post-crash firmware stall at PC `0x23f6b0924` (2 of 4 post-crash
  boots). It survives a QMP `system_reset` but not a new QEMU process, so
  it is device or memory state that a reset keeps. It only follows the
  resume crash, so the workaround avoids it. Not root-caused.
- What waits on more than 64 objects in the patched-resume shutdown
  (bugcheck 0xC). No symbols here.
