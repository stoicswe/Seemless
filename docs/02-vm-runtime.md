# 02 — VM runtime

The runtime is "QEMU with exactly one configuration". All knobs live in
`SeemlessKit`; only the settings listed under "User-editable settings" below
can be changed, and only while the VM is stopped.

## Building the host stack

Everything installs into `build/prefix`. `scripts/build-deps.sh` must be
idempotent and pin every source by commit SHA in `scripts/versions.lock`.
Every component is built with `MACOSX_DEPLOYMENT_TARGET=26.0` (D10); without
it clang targets the build machine's SDK and the result will not run on
older macOS 26 releases.

Build order (from UTM's Triton post, which is the authoritative recipe —
read it before starting, link in [11-references.md](11-references.md)):

1. ANGLE (Metal backend) and libepoxy
2. DXMT (UTM fork, built as a native macOS dylib with shared texture/fence exports)
3. MoltenVK (host Vulkan driver: D3D12 via vkd3d-proton, and Venus)
4. vkd3d-proton built as a native macOS arm64 library against MoltenVK (D3D12 backend, see 04)
   - optional, not bundled: d3dmetal-native (x86_64) for a user-supplied `D3DMetal.framework`
5. virglrenderer (`utmapp/virglrenderer`, `macos-next`) with venus + neptune
6. swtpm + libtpms
7. QEMU (`utmapp/qemu`, `utm-edition`) + `patches/qemu/*.patch`

Other QEMU dependencies: glib, pixman, libslirp, libusb, zstd. Prefer building
them into the prefix over Homebrew so the app bundle is self-contained;
Homebrew is acceptable for M0 only.

Implemented by `scripts/build-deps.sh` (S1, 2026-11-23): it builds this order
with the deviations listed in `docs/spikes/S1-host-stack-build.md`, and
`scripts/smoke-qemu.sh` boots the result to firmware. For release, configure
QEMU with `--disable-tcg` (HVF only) to avoid the `allow-jit` entitlement.

## Baseline command line

Known-good starting point, taken from UTM's published Triton run instructions
and extended. `VMConfig.qemuArguments()` must generate this and a snapshot
test must pin it.

```
qemu-system-aarch64
  -name seemless -nodefaults -no-user-config
  -machine virt,highmem=on
  -accel hvf,ipa-granule-size=0x1000
  -cpu host
  -smp cpus=N,sockets=1,cores=N,threads=1
  -m <MiB>
  -drive if=pflash,format=raw,unit=0,readonly=on,file=<prefix>/share/qemu/edk2-aarch64-code.fd
  -drive if=pflash,format=raw,unit=1,file=<vm>/efi_vars.fd
  -device virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2
  -display seemless,gl=es,service=app.seemless.display.<hash of run dir>   # patches/qemu/0001; `cocoa,gl=es` until WP3.2
  -device nvme,drive=sys,serial=seemless0
  -drive if=none,id=sys,file=<vm>/system.qcow2,format=qcow2,discard=unmap,cache=writethrough,aio=threads
  -device qemu-xhci,id=usb
  -device usb-kbd -device usb-tablet                   # see input notes
  -netdev vmnet-shared,id=n0  (fallback: user,id=n0)
  -device virtio-net-pci,netdev=n0,mac=<stable>
  -device virtio-serial-pci
  -chardev socket,id=agent,path=<run>/agent.sock,server=on,wait=off
  -device virtserialport,chardev=agent,name=app.seemless.agent.0
  -chardev socket,id=bulk,path=<run>/bulk.sock,server=on,wait=off
  -device virtserialport,chardev=bulk,name=app.seemless.bulk.0
  -chardev socket,id=tpm,path=<run>/swtpm.sock
  -tpmdev emulator,id=tpm0,chardev=tpm -device tpm-tis-device,tpmdev=tpm0
  -audiodev coreaudio,id=a0 -device usb-audio,audiodev=a0   # or virtio-sound, see below
  -rtc base=localtime
  -qmp unix:<run>/qmp.sock,server=on,wait=off       # owner (VMProcess)
  -qmp unix:<run>/ctl.sock,server=on,wait=off       # other controllers (VMRemote)
  -qmp unix:<run>/input.sock,server=on,wait=off     # Zen mode guest input
  -S                                                    # start paused; app sends `cont`
```

Environment for the QEMU process (from UTM's recipe):
`ANGLE_DEFAULT_PLATFORM=metal`, `DYLD_FALLBACK_LIBRARY_PATH=<prefix>/lib:<angle>`,
and `D3DMETAL_FRAMEWORK_PATH` when D3DMetal is selected.

### Notes on each choice

| Area | Choice | Reason / caveat |
|------|--------|-----------------|
| Machine | `virt`, GICv3 | UTM 5.0 notes GICv3 is always used now and is faster |
| HVF | `ipa-granule-size=0x1000` | UTM fork option; Windows expects 4K pages while Apple silicon hosts use 16K. Treat as required |
| CPU | `-cpu host`; default vCPUs = performance-core count, capped at 8 | Never give efficiency cores' worth of vCPUs to a game; see 08 |
| RAM | Default `min(8 GiB, half of host)`; 4 GiB floor | virtio-balloon later for reclaim |
| Firmware | edk2 aarch64, separate vars file per VM: a zeroed 64 MiB file (QEMU ships no aarch64 vars template; S1) | Secure Boot variant only when D12 is resolved |
| Boot disk | NVMe | Windows has an inbox NVMe driver, so WinPE needs **no injected storage driver**. This is what makes the image pipeline in 03 simple |
| Disk format | qcow2 on APFS | Snapshots and the golden-image overlay model need it. Benchmark raw vs qcow2 in M7 |
| GPU | `virtio-ramfb-gl` with `venus=true,neptune=true` | ramfb gives firmware/WinPE a framebuffer before drivers load. `max_outputs=2` for the atlas (verify the UTM fork supports it on this device: spike S5) |
| Network | `vmnet-shared` preferred, slirp fallback | vmnet needs either root or the `com.apple.vm.networking` entitlement, which Apple grants restrictively. Ship slirp as the default until that is resolved; slirp is fine for most apps but has no inbound and ICMP quirks |
| TPM | swtpm over unix socket | Lets Windows see TPM 2.0 without registry bypasses |
| Audio | Start with `usb-audio` (inbox driver) | Evaluate `virtio-sound` + viosnd for latency in M7 |
| Input | `usb-tablet` for absolute, plus a relative mouse for game mode | virtio-input has lower overhead but needs a guest driver (vioinput); evaluate in M7 |
| Clock | `-rtc base=localtime` | Windows assumes local-time RTC; agent also resyncs time after resume |

## User-editable settings

`VMConfig` (`vms/<name>/config.json`). Fields added later decode with
defaults, so old configs keep loading. Edited through `VMManager.update`
(app settings sheet, `seemlessctl vm set`), which refuses changes while the
VM runs, grows the disk when `diskSizeGiB` rises and refuses to shrink it.

| Setting | Values | Effect on the command line |
|---------|--------|----------------------------|
| CPU, RAM, disk | validated against the host | `-smp`, `-m`, `qemu-img resize` |
| Graphics backend | `dxmt` / `d3dmetal` | `NPT_BACKEND` |
| Network | user / vmnet-shared / none, plus loopback port forwards | `-netdev` |
| Boot order | `disk-first` (default) / `removable-first` | `bootindex` on the NVMe disk and USB drives; edk2 reads it from fw_cfg |
| Firmware menu wait | 0–30 s (default 0) | `-boot menu=on,splash-time=<ms>`; shows edk2's "Start boot option" countdown (checked by screendump, 2026-11-23) |
| TPM 2.0 | on (default) / off | off drops the TPM devices and swtpm is not started (`RunningVM.swtpmPID` = 0) |
| Attached media | ISOs (USB CD-ROM) and raw images (USB disk), absolute paths | persisted drives `m0`, `m1`… come before per-launch drives |
| Shared folders | later (S7) | |

Per-launch only (`LaunchOptions.bootKeys`): **firmware setup** presses Escape
for 8 s after the vCPUs start, which opens the edk2 front page (Device
Manager, Boot Manager, Boot Maintenance Manager; checked by screendump);
**CD prompt** presses Space for 40 s to answer "Press any key to boot from
CD". Maintenance actions on a stopped VM: reset UEFI variables (blank 64 MiB
vars file), clear TPM (empty state dir).

Note: the edk2 build from UTM's QEMU fork shows UTM's logo at boot. Replace
it with our own firmware build before any release (docs/10).

## Storage layout on the host

```
~/Library/Application Support/Seemless/
├── images/
│   └── win11-<build>-<recipehash>/base.qcow2     # golden image, read-only once sealed
├── vms/default/
│   ├── config.json                               # VMConfig
│   ├── system.qcow2                              # overlay backed by base.qcow2
│   ├── efi_vars.fd
│   ├── tpm/                                      # swtpm state
│   └── state/                                    # suspend-to-disk (migration file)
├── cache/                                        # downloaded ISOs, guest tools
└── run/<pid>/                                    # sockets (keep paths under 104 bytes)
```

- One VM in v1. The layout allows more later without migration.
- "Reset Windows" = delete `system.qcow2`, recreate overlay. User files should
  be steered to the shared folder so a reset is cheap.

## Lifecycle

`SeemlessKit.VMProcess` is a state machine; every transition is logged.

```
stopped → starting → running ⇄ paused
                        │
                        ├→ suspending → suspended → resuming → running
                        └→ stopping → stopped
              any state → crashed
```

| Operation | Mechanism |
|-----------|-----------|
| Start | Launch swtpm, launch QEMU with `-S`, connect QMP, negotiate capabilities, `cont` |
| Graceful stop | Agent `Shutdown` request; fall back to QMP `system_powerdown`; hard `quit` after timeout |
| Pause/resume | QMP `stop` / `cont`. Pause automatically after N minutes with no guest windows open (configurable) |
| Suspend to disk | **Guest hibernate** (Windows `shutdown /h`, triggered by the agent in M4), then quit; resume is a normal start that boots from `hiberfil.sys`. **Decided by S6 (2026-11-23)**: QEMU snapshot and migrate-to-file are blocked with the 3D driver loaded (`virgl is not yet migratable`, plus non-migratable `nvme` and `usb-audio`). Hibernate does not depend on QEMU device state. Its resume with the 3D driver is not yet validated. Short pauses stay QMP `stop`/`cont` in RAM (~0.2 ms, lost if QEMU exits). See `docs/spikes/S6-fast-resume.md` |
| Snapshots | qcow2 internal snapshots via QMP (UTM 5.0 ships this for QEMU VMs) |
| Crash handling | Helper detects child exit; app shows a recoverable error with logs; render-server crashes are reported separately and should not stop the VM |
| Implemented (M1) | `VMProcess` (owner) and `VMRemote` (other processes, via `vms/<name>/running.json`); stop escalates ACPI power button → QMP `quit` → SIGTERM → SIGKILL; restart = QMP `system_reset`; the last 5 QEMU logs are kept in `vms/<name>/logs/`. CLI: `seemlessctl vm run|status|pause|resume|restart|stop` |
| `VMManager` | One actor over every VM in a storage root: list, status (owned by this process or started elsewhere), start/pause/resume/reset/stop, settings, media, firmware/TPM reset, snapshots. Used by the app and the CLI's `vm set`/`media`/`firmware` commands. Each VM started by one process gets its own `run/<pid>/<id>/` |

## QMP client

Implemented (M1): `kit/Sources/SeemlessKit/QMPClient.swift`, a minimal async
Swift actor rather than QEMU's QAPI C bindings: newline-delimited JSON,
`execute`/`return`/`error` correlation by `id`, and an `AsyncStream` of
events (`SHUTDOWN`, `STOP`, `RESUME`, ...). Lessons from building it:

- **Three QMP monitors.** QEMU serves one client per monitor, so the owner
  (`VMProcess`) uses `qmp.sock` and every other controller (`VMRemote`, a
  second `seemlessctl`) uses `ctl.sock` for short connections. Zen mode
  sends input for as long as it runs, so it has its own `input.sock`
  (2026-11-24: holding `ctl.sock` locked `vm stop` and the app out).
- **Never block the Swift concurrency pool on a socket.** `FileHandle.bytes`
  does, and a handful of idle connections then starve all other tasks. Socket
  reads run on a dedicated thread (`LineReader`).
- **Waits with timeouts must be cancellable.** A task group waits for every
  child, so racing an uncancellable continuation against a timer never times
  out. Use one continuation resumed by whichever event comes first.

## Patches we expect to carry on QEMU

Keep each as an independent, minimal patch file with a header explaining why.

| Patch | Purpose | Milestone |
|-------|---------|-----------|
| `ui/seemless` display backend ✅ (`patches/qemu/0001`, WP3.1) | Export each scanout as a ring of IOSurfaces (Mach send rights, bootstrap name), frame/cursor/pointer events, size requests. Input stays on QMP `input-send-event` | M3 |
| Cursor shape/visibility/hotspot events ✅ (in `0001`: CURSOR, MOUSE) | Host draws the real Mac cursor; needed for seamless and game-mode capture detection | M3 |
| vCPU thread QoS | Set `QOS_CLASS_USER_INTERACTIVE` on vCPU threads | M7 |
| Emulated Xbox 360 USB controller (`usb-xinput`) | Windows binds its inbox XUSB driver; host feeds it from GameController.framework | M7 |

Anything larger than this list should be questioned: prefer solving it in the
agent or the app.
