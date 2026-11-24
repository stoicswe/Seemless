# S4 — Unattended apply-time install

Status: **done** (2026-11-23). D8 decided.

Media: `Windows11_Client_arm64_en-us_26300_9457.iso` (build 26300.9457,
Windows 11 Pro = index 3, en-US). Host: M3, macOS 27.3, host stack from S1.

## Results

| Question | Answer | Evidence |
|----------|--------|----------|
| Does the `windowsPE` `RunSynchronous` hook in `autounattend.xml` start `apply.cmd` on this media? | **Yes.** Setup's own pages never appeared; `apply.log` was written from WinPE | `apply.log` first lines; screendump shows `X:\windows\SYSTEM32\cmd.exe` over "Windows 11 Setup" |
| `boot.wim` / `winpeshl.ini` fallback needed? | No | — |
| Does the Space-key loop get past "Press any key to boot from CD"? | Yes | WinPE started every run |
| Is the ISO found from WinPE? | Yes, as `D:` (`D:\sources\install.wim`) | `apply.log` |
| Is the payload disk found? | Yes, as `C:` (label SEEMLESS, FAT32, "Removable") | diskpart `detail disk 1` |
| Is QEMU's NVMe disk visible in WinPE without injected drivers? | Yes: `QEMU NVMe Ctrl`, `Type : NVMe`, location `PCIROOT(0)#PCI(0200)#NVME(P00T00L00)` | diskpart `detail disk 0` |
| Does the whole pipeline run unattended? | **Yes, through first boot**: partition, DISM apply (`/Compact`, 2 min 27 s), inventory, unattend copy, `bcdboot`, reboot, specialize, SetupComplete → `firstboot.cmd` → `FIRSTBOOT_OK`, power-off. **4 min 53 s** end to end, zero keystrokes (4 vCPU, 8 GiB) | `status.txt`, `apply.log`, `setupact.log` |
| Which WinPE tools exist? | diskpart, dism, bcdboot, bcdedit, reg, wpeutil, xcopy, takeown, icacls. **Not** findstr, where | `apply.log` tools stage |
| When does SetupComplete.cmd run? | **Before OOBE** (22 s after the specialize actions, licence never accepted, VM already off). OOBE runs on the next start | `setupact.log` timestamps; next boot showed the licence page |
| Licence page | Shown on the first normal start when not accepted on the host. Not clicked in this session: that is the owner's decision | screendump of the next boot |
| Inventory | 45 provisioned apps, 370 capabilities, 139 features; saved to `image/recipes/inventory/26300.9457-pro-arm64/` for WP2.3 | DISM output |

## Bugs found on real media

1. **WinPE has no `findstr.exe` (and no `where.exe`).** `findstr` fails with
   errorlevel 9009 and its error goes to the console, not the log, so the
   NVMe check in `apply.cmd` silently never matched: `ERROR find-disk no NVMe
   disk found` on the first two runs. Fixed by parsing diskpart's output with
   `for /f "tokens=1,2,3"` (`Type`, `:`, `NVMe`). The removal-recipe step for
   provisioned apps used `findstr` too and would have removed nothing without
   an error; rewritten with a pure-cmd prefix match. `apply.cmd` now starts
   with a tools stage that logs which tools exist (`%%~$PATH:t`) and stops if
   a required one is missing.
2. **`firstboot.cmd` deleted `Panther\unattend.xml` before OOBE.** Because
   SetupComplete runs before OOBE on this build, OOBE would have found no
   answer file: no `Seemless` account, no auto-logon, every OOBE page shown.
   Fixed: `firstboot.cmd` no longer touches it; `unattend.xml` deletes it in
   `FirstLogonCommands` (after OOBE, at the first logon). Regression test
   `answerFileDeletedAtFirstLogonNotBeforeOOBE`. **The fixed path has not
   run yet**: it needs the licence accepted.
3. **A missing batch label is silent.** `call :try` to a label that did not
   exist skipped every recipe step; the error only reached the WinPE
   console. Found because the new after-recipe inventory still listed
   everything. `RecipeTests.everyCalledLabelExists` now checks all scripts.
4. diskpart's redirected output is plain ANSI with CRLF (checked byte-wise);
   not UTF-16, which was the first (wrong) guess.

## With the default recipe (WP2.3)

Build with `seemless-default`: `FIRSTBOOT_OK`, 12 min 32 s (recipe steps
about 2 min). After-recipe inventory: 22 of 45 provisioned apps removed,
every keep still present; 8 capabilities removed; `WorkFolders-Client` and
`SmbDirect` disabled; both `.reg` files imported (ANSI works with
`reg import`). One warning: `Microsoft.Windows.Sense.Client` is permanent
(0x800F0825), now dropped from the recipes. WinPE's X: scratch space is
too small for servicing, so DISM uses `/ScratchDir` on the new volume.

## Close-out (owner, 2026-11-23)

The owner rebuilt a Lean VM, started it and accepted the licence. They then
confirmed three things, which closes S4:

- the local account logs on automatically, with no further OOBE pages;
- the registry policies take effect in the logged-on session;
- Open in Seemless starts an installer (Firefox) in Windows.

The licence click is the one deliberate keystroke. These checks were done by
the owner by hand: no session log or screendump of them was kept.

Correction (S2, 2026-11-23): the account is **not** in Administrators,
although the answer file asks for it, so nothing in the guest can elevate.
The owner's checks above don't show this, because auto-logon and per-user
installers work without admin. Fixed the same day: the account is now
created by `image/guest/setup-account.ps1` as SYSTEM before OOBE (docs/03
"Shell configuration"). The FirstLogonCommand that was meant to delete the
answer file also failed under the non-admin user; a SYSTEM task does that
now.

## Still to check

- Idle RAM and disk use, stock vs `seemless-default` (G4/WP2.5).
