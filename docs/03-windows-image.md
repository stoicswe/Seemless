# 03 — Windows image pipeline

Goal: turn a stock Windows 11 ARM64 ISO supplied by the user into a sealed,
minimal golden image (`base.qcow2`) with our drivers and agent installed,
without the user seeing Windows Setup.

## What Tiny11 Builder is today (checked 2026-11-23)

- `ntdevlabs/tiny11builder` default branch is `winui-preview`. It is now a
  **WinUI 3 / C# Windows desktop app** (v0.2.0) with a `Tiny11Builder.Core`
  library, plus the original `tiny11maker.ps1` / `tiny11Coremaker.ps1`.
- It **only runs on Windows** (Windows 10 2004+ host). It drives Microsoft's
  DISM and `oscdimg` (from the ADK), which do not exist on macOS.
- It supports x64 **and ARM64** images, Windows 11 22H2 and newer.
- Three modes:
  - **Tiny11**: removes bundled apps, Edge/WebView2 and OneDrive binaries;
    applies hardware-check, reserved-storage and auto-encryption settings.
    Keeps Windows Update, Defender, WinRE, Store and shared runtimes.
  - **Tiny11 Core**: also deletes most of WinSxS, removes WinRE, disables
    Update and Defender. Unserviceable; "disposable test VMs" only.
  - **Custom**: pick removal groups; recipes are JSON (`recipes/cd700-custom.json`
    shows the schema and option ids such as `xbox`, `edge`, `onedrive`,
    `copilot`, `widgets`, `hardware-bypass`, `reserved-storage`, `remove-wow64`).
- **It has no licence.** Its own `NOTICE.md` says the upstream checkout
  contains no licence file and that a public repository alone does not grant
  redistribution rights.

Consequences for us:

1. We cannot run it on the Mac host.
2. We must not copy its code or bundle its binaries. We may use its documented
   behaviour as a reference for *what* to remove, and we can let users bring
   an ISO they built with it. Ask the author about licensing before release
   (tracked in [10-risks-licensing.md](10-risks-licensing.md)).

## Strategy

Three supported inputs, in order of implementation:

| Path | Input | How the Tiny11 result is achieved | Status |
|------|-------|-----------------------------------|--------|
| **A. Apply-time debloat** (default) | Stock Microsoft ARM64 ISO | Our script runs inside the ISO's own WinPE, applies `install.wim` with DISM, then removes the Tiny11 set offline with the same DISM | D8, spike S4 |
| **B. Bring your own Tiny11 ISO** | ISO the user built with Tiny11 Builder on a Windows machine | Already debloated; we only do apply + driver/agent injection | Cheap once A exists |
| **C. Builder VM** | Stock ISO | Install stock Windows in a throwaway VM, run the real Tiny11 Builder ARM64 inside it with a recipe, export the ISO, then path B | Later, only if exact Tiny11 fidelity is demanded |

Never use **Tiny11 Core** as our base: games and apps need Windows Update,
servicing, the component store (for .NET, DirectX optional features, language
packs) and WOW64/Prism. Our recipe is "Tiny11 regular, plus gaming keeps".

### Why path A works on macOS with no Microsoft tools on the host

The ISO boots into WinPE, which already contains `dism.exe`, `diskpart`,
`reg.exe`, `bcdboot` and `cmd`. Windows Setup supports an answer file whose
`windowsPE` pass can run commands (`RunSynchronous`) before Setup's own UI
does anything. We attach a second, tiny volume labelled for answer-file
discovery that carries `autounattend.xml`, our script, our drivers and our
agent. The script does the whole installation itself and reboots, so Setup's
hardware checks, edition picker, EULA and OOBE-account screens never appear.

Because the system disk is NVMe (inbox driver) and the display is ramfb/GOP,
WinPE needs no injected drivers.

> This flow is the main unverified assumption in the image pipeline.
> Spike S4 must prove: (1) the `windowsPE` `RunSynchronous` hook fires on
> 24H2+ ARM64 media (which uses the newer SetupHost flow; Tiny11 Builder's
> notes mention falling back to the legacy `sources\setup.exe`), and
> (2) a DISM-applied, offline-debloated image boots to a desktop. Fallback if
> (1) fails: build a custom boot path on the host by writing our own
> `winpeshl.ini` into `boot.wim` with `wimlib` (open source, runs on macOS).

## Pipeline stages

`seemlessctl image build --iso <path> --recipe seemless-gaming` runs:

| # | Stage | Where | Detail |
|---|-------|-------|--------|
| 1 | **Acquire** | Host | User picks an ISO, or we open Microsoft's ARM64 download page. Do not scrape or automate around Microsoft's session-gated links in v1 |
| 2 | **Inspect** | Host | Read the ISO (UDF) with a small reader or `hdiutil`; parse `sources/install.wim|esd` XML header for architecture, build, editions, languages. Reject non-ARM64, pre-22H2, Server. Warn on Home edition (no RDP/Group Policy; fine otherwise) |
| 3 | **Stage payload** | Host | Build `seemless-setup.img` (FAT/exFAT or ISO9660) containing `autounattend.xml`, `apply.cmd`, the recipe rendered to plain command lists, `drivers\`, `agent\`, `unattend-oobe.xml`, `firstboot.cmd` |
| 4 | **Create disk** | Host | `qemu-img create -f qcow2 base.qcow2 <size>` (default 64 GiB, sparse) |
| 5 | **WinPE apply** | Guest (WinPE) | See "apply.cmd" below. Headless; progress reported to host over a serial port |
| 6 | **First boot** | Guest | Specialize + OOBE driven by `unattend.xml`; `firstboot.cmd` finishes online-only removals, installs runtimes, starts agent |
| 7 | **Seal** | Guest → host | Cleanup, optional `compact /compactos:always`, TRIM, clean shutdown; host converts/compacts (`qemu-img convert -c` optional), writes `manifest.json`, marks image read-only |

The builder VM runs with the same runtime as 02 but with: both ISOs attached
as USB/NVMe CD-ROMs, no network (keeps Setup from pulling updates and avoids
the Microsoft-account requirement), an extra `-serial` chardev for progress,
and desktop-mode display hidden unless `--debug-display`.

Total time target: under 20 minutes on an M3.

## `apply.cmd` (WinPE phase)

Plain batch; WinPE has no PowerShell.

1. Find our payload volume and the Windows media by marker files.
2. `diskpart`: GPT; EFI system partition (260 MB FAT32), MSR (16 MB),
   Windows (rest, NTFS). No recovery partition in v1 (see "WinRE" below).
3. `dism /Apply-Image /ImageFile:<media>\sources\install.wim /Index:<n> /ApplyDir:W:\`
   (`/Compact` if the recipe says so). Handle `install.esd` too.
4. Offline servicing against `/Image:W:\`, driven by the rendered recipe:
   - `dism /Get-ProvisionedAppxPackages` → match by package-name prefix →
     `dism /Remove-ProvisionedAppxPackage`
   - `dism /Remove-Capability`, `/Remove-Package`, `/Disable-Feature` for
     listed capabilities/features
   - Delete Edge, EdgeWebView (see keeps), OneDrive setup payloads by path
   - `reg load` the offline `SOFTWARE`, `SYSTEM`, `DEFAULT`, `NTUSER.DAT`
     hives; apply policy keys; `reg unload`
   - Remove listed scheduled-task XML files/registry entries
5. `dism /Image:W:\ /Add-Driver /Driver:<payload>\drivers /Recurse`
   (netkvm, vioserial, viofs, viogpu3d + Triton UMD, viosnd…).
6. Copy `agent\` to `W:\Program Files\Seemless\`; copy `unattend-oobe.xml` to
   `W:\Windows\Panther\unattend.xml`; copy `firstboot.cmd` and register it via
   `SetupComplete.cmd` (`W:\Windows\Setup\Scripts\`).
7. `bcdboot W:\Windows /s S: /f UEFI`; if drivers are test-signed,
   `bcdedit /store ... /set {default} testsigning on` (D12).
8. Write a result code to the progress serial port; `wpeutil shutdown`.

Every step logs to the serial port in a line protocol
(`STAGE <name>`, `PROGRESS <0-100>`, `ERROR <code> <text>`) so the host can
show progress and fail fast.

## Recipe format

`image/recipes/*.json` is ours (do not reuse Tiny11 Builder's schema; do keep
a mapping comment to its option ids for traceability).

```json
{
  "schema": 1,
  "name": "seemless-gaming",
  "based_on": "Tiny11 Builder 0.2.0 'Tiny11' preset (behavioural reference)",
  "compact_os": true,
  "remove_appx_prefixes": ["Clipchamp.Clipchamp", "Microsoft.BingNews", "..."],
  "remove_capabilities": ["..."],
  "disable_features": ["..."],
  "delete_paths": ["Program Files (x86)\\Microsoft\\Edge", "..."],
  "registry": [{"hive": "SOFTWARE", "key": "...", "name": "...", "type": "REG_DWORD", "data": 1}],
  "remove_tasks": ["..."],
  "keep": ["Microsoft.VCLibs", "Microsoft.UI.Xaml", "Microsoft.DesktopAppInstaller", "..."]
}
```

The exact lists must be produced in M2 by enumerating a real 24H2/25H2 ARM64
image (`dism /Get-ProvisionedAppxPackages`, `/Get-Capabilities`,
`/Get-Features`) and comparing against Tiny11 Builder's removal plan export.
Do not hand-write lists from memory. The recipe resolver must skip entries
that are absent from a given build and report them, never fail on them.

### Removal groups (default recipe)

Consumer apps (Clipchamp, News, Weather, Solitaire, Teams, Outlook, Phone
Link, Feedback Hub, Maps, Media Player/Movies, Dev Home, Copilot app, Quick
Assist, Sticky Notes, To Do, Power Automate, Family), OneDrive, Edge browser,
widgets, ads/suggestions/consumer features, telemetry level to minimum,
reserved storage off, BitLocker auto-device-encryption off, hibernation file
off (unless S6 picks guest hibernate), search indexing of non-profile
locations off, System Restore off.

### Gaming and compatibility keeps (deviations from Tiny11)

| Keep | Why |
|------|-----|
| WOW64 and Prism emulation components | Every x86/x64 app |
| Component store, Windows Update, servicing stack | .NET, optional features, security |
| Defender | Keep on by default, add exclusions for the shared-folder mount; offer "performance mode" off switch later |
| Microsoft Store, App Installer (winget), VCLibs, UI.Xaml, .NET native runtimes | Many launchers and Game Pass depend on them |
| **Edge WebView2 runtime** | Tiny11 removes it, but Steam-adjacent launchers, Epic, Battle.net, Office and many apps embed WebView2. Remove the Edge *browser*, keep WebView2 (or reinstall the Evergreen runtime at first boot) |
| Xbox Gaming Services / Xbox Identity Provider / Game Bar components | `seemless-gaming` keeps them (Game Pass, Xbox sign-in in games). `seemless-default` removes them |
| DirectX legacy runtimes (d3dx9, xinput1_3, xaudio2_7), VC++ redistributables 2005–2022 x86/x64/arm64 | Not removed by Tiny11 but not present either: `firstboot.cmd` installs them from the guest tools ISO or winget |
| Media Foundation codecs | In-game video |
| WinRE | Dropped in v1 for size; "Reset Windows" is a host-side overlay reset instead |

### Shell configuration (for seamless mode)

Applied by registry/policy in the image, not by killing Explorer:

- Auto-logon to a single local administrator account (password generated on
  the host, stored in the Mac Keychain; needed for agent-initiated elevation
  flows and RDP-less session management).
- No lock screen, no screen saver, display never sleeps, no "let's finish
  setting up" nags, no first-logon animation.
- Taskbar auto-hide, no desktop icons, solid black wallpaper, notifications
  banner suppression (the agent forwards them instead), no startup sound.
- High-performance power plan; USB selective suspend off.
- Time zone and locale taken from the host at build time; keyboard layout too.
- Explorer stays the shell (file dialogs, tray and app lifecycles depend on
  it); see [05-seamless-mode.md](05-seamless-mode.md) for how its windows are
  filtered.

## Activation and licensing

- The image is unactivated unless the user enters a key (Settings in guest, or
  a host UI that passes it to `slmgr` via the agent). Unactivated Windows
  works with cosmetic limits. Never ship or inject keys; never bypass
  activation.
- Hardware-requirement bypass keys are unnecessary on path A (we do not run
  Setup's checks) and the VM provides TPM 2.0 anyway.

## Image manifest and updates

`manifest.json` next to `base.qcow2`: Windows build, edition, language,
recipe name + hash, driver versions, agent version, creation date, tool
versions. The overlay records which base it was created from.

- **Agent/driver updates** ship in the app bundle as `seemless-tools.iso`;
  the host attaches it and the agent service self-updates (see 06).
- **Windows updates** run inside the overlay as normal. Feature updates
  re-provision removed apps; the agent re-applies the recipe's online-capable
  subset after each feature update (`Remove-AppxProvisionedPackage -Online`).
- Rebuilding the base from a newer ISO is the "big update" path.
