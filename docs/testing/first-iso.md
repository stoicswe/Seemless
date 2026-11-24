# Runbook: first tests with a Windows 11 ARM64 ISO

Everything below runs today against the built host stack. What has **not**
happened yet is a boot of real Windows media, so each step lists what to
watch for and where the evidence lands. Results go into the spike notes
(`docs/spikes/S2-*.md`, `S4-*.md`) and `docs/STATUS.md`.

## 0. Prerequisites

```bash
scripts/bootstrap.sh                 # tools
scripts/build-deps.sh all            # host stack in build/prefix (S1)
swift build --package-path kit       # seemlessctl
alias seemlessctl="$PWD/kit/.build/debug/seemlessctl"
seemlessctl stack                    # "complete yes"
```

Get the ISO from Microsoft's Windows 11 ARM64 download page and check it:

```bash
seemlessctl image inspect ~/Downloads/Win11_ARM64.iso
```

Expect `ok` next to the editions and `default edition: index N (Windows 11 Pro)`.
`NO … architecture is x64` means it is the wrong ISO.

## A. Unattended install (spike S4)

```bash
seemlessctl image build --name win --iso ~/Downloads/Win11_ARM64.iso
```

What happens, and what to watch in the QEMU window:

| Phase | Expected | If not |
|-------|----------|--------|
| Firmware → "Press any key to boot from CD" | Skipped automatically: the builder presses Space for 40 s | If the window shows the UEFI shell or a boot-failure screen, the key timing missed: note it; press a key yourself |
| WinPE starts, briefly shows Setup | Our `apply.cmd` takes over within a minute (a console window may flash). Setup's language/edition pages must **not** appear | If Setup's own pages appear, the `windowsPE` `RunSynchronous` hook did not fire on this media (the S4 question). Close the VM; see "S4 fallback" below |
| DISM apply (5–15 min) | No visible progress in the window; host disk activity | `apply.log` afterwards shows the stage that failed |
| Reboot into Windows, specialize | Windows sets up devices (about 2 min) | |
| First boot finishes | VM powers off by itself (`firstboot.cmd` runs from SetupComplete, **before OOBE**). Whole build ≈ 5 min on an M3 (S4) | Times out after 120 min (`--timeout`) |
| First normal start (`vm run` or Start in the app) | OOBE: **Microsoft's licence page appears** unless you passed `--accept-windows-license`. Accepting it is your decision. Then no other OOBE pages: the `Seemless` account is created and logs on by itself | Other OOBE pages, or a login prompt, mean an `unattend.xml` setting was ignored: note which (not yet observed: S4 stopped at the licence page) |

Afterwards:

```bash
ls ~/Library/Application\ Support/Seemless/vms/win/logs/image-build-*/
```

| File | Meaning |
|------|---------|
| `status.txt` | `FIRSTBOOT_OK` = whole pipeline worked. `APPLIED` = WinPE part worked, first boot did not report back. `ERROR <stage> …` = `apply.cmd` failed at that stage. Missing = `apply.cmd` never ran |
| `apply.log` | Every command `apply.cmd` ran, with output |
| `inventory-*.txt` | Real DISM lists of provisioned apps, capabilities, features. **Input for the removal recipe (WP2.3)** |
| `setupact.log`, `firstboot.log` | Windows' own setup log and our first-boot script |

Then boot it normally:

```bash
seemlessctl vm run --name win
```

The account is `Seemless`; its password is in the Keychain:

```bash
security find-generic-password -s app.seemless.windows-account -a win -w
```

Expected gaps at this stage (not failures): no network (the `virtio-net`
driver is not injected yet, so pass `--drivers` with an ARM64 netkvm folder or
install drivers in step B), no GPU acceleration until the 3D driver is
installed, display at a fixed resolution.

### S4 fallback

If Setup ignores the `RunSynchronous` hook on this media, the planned fallback
(docs/03) is to put our own `winpeshl.ini` into a copy of `boot.wim` with
`wimlib` so WinPE starts `apply.cmd` directly. That is the next work item if
it happens; record the Windows build number in the spike note.

## B. Manual install and graphics (spike S2)

Use this to test the Direct3D path independently of the unattended pipeline.

```bash
seemlessctl vm create --name manual
seemlessctl vm run --name manual --cdrom ~/Downloads/Win11_ARM64.iso
```

- Press a key at "Press any key to boot from CD" yourself.
- Windows 11's hardware check may refuse this VM: the firmware in use is
  edk2 **without** Secure Boot (docs/01 D12). If it does, press Shift+F10 in
  Setup and add `HKLM\SYSTEM\Setup\LabConfig` → `BypassSecureBootCheck`
  (DWORD 1), or use path A, which does not run Setup's checks. Record which
  happened.
- No network during setup is expected (no virtio-net driver); choose the
  offline/limited setup option.

Then install the guest drivers with UTM's experimental 3D driver, following
UTM's Windows guide (docs/11 has the links): attach the guest tools ISO
as a second `--cdrom` on the next boot. Record in the S2 note:

1. `dxdiag` (driver name, feature levels).
2. 3DMark Fire Strike score with `NPT_BACKEND=dxmt` (the default).
3. How the driver is signed (`signtool verify /v /kp <file>.sys`, or the
   driver's properties): this answers D12.
4. Any crash, black screen or hang, with `~/Library/Application Support/Seemless/vms/manual/logs/qemu-*.log`.

This is the first time virglrenderer, Venus and Neptune actually run (QEMU
starts the renderer only when a guest driver talks to it, S1), so render-server
errors in the QEMU log are the most likely new failures.

## C. Lifecycle checks with real Windows

With a working install, repeat the lifecycle in a second terminal:

```bash
seemlessctl vm status --name win
seemlessctl vm pause  --name win      # Windows freezes
seemlessctl vm resume --name win
seemlessctl vm stop   --name win      # Windows should shut down cleanly ("guestShutdown")
```

`vm stop` returning `guestShutdown` (not `quit`) confirms the ACPI power
button reaches Windows. Also try Ctrl-C in the `vm run` terminal once.

Snapshot the clean install before experimenting:

```bash
seemlessctl disk snapshot create clean-install --name win
```
