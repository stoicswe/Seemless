# Status

Updated: 2026-11-24 (Show Display opens the app's desktop window for exported displays)

## Done

- Phase 1 planning documents (`docs/00`–`11`), `CLAUDE.md`.
- **WP0.1 repo scaffolding** (2026-11-23):
  - Directory layout from `docs/01` with README stubs.
  - `scripts/bootstrap.sh` (tool check, milestone-grouped), `scripts/check.sh`
    (all VM-free checks), `.github/workflows/ci.yml` (runs `check.sh`).
  - `kit/`: `SeemlessKit` (`StorageLayout` from docs/02), `seemlessctl`
    (`--version`, `paths`), 4 Swift tests passing.
  - `guest/agent/`: Rust workspace with the 8 crates from docs/06, toolchain
    pinned to 1.99.1; builds and tests on macOS (no tests yet).
  - `scripts/versions.lock`: candidate SHAs for every upstream source,
    unbuilt; `THIRD_PARTY.md` with licences as GitHub reports them.
- **S1 host stack build** (2026-11-23): every component builds from pinned
  SHAs, arm64, minos 26.0; QEMU boots to firmware with the production GPU
  device, swtpm TPM 2.0 and QMP (headless and windowed). Findings and
  deviations: `docs/spikes/S1-host-stack-build.md`.
- **M1 VM runtime core** (2026-11-23): `VMConfig` + QEMU command generation
  (snapshot-tested against docs/02), QMP client, disk/firmware tooling,
  `VMProcess` lifecycle, `VMRemote`, and the `seemlessctl vm`/`disk`/`stack`
  commands. Tested by booting real QEMU to firmware (no Windows needed).
- **M2 image pipeline, ISO-free parts** (2026-11-23): ISO/WIM inspector,
  payload disk builder, answer files, `apply.cmd`, first-boot scripts,
  Keychain credentials, `seemlessctl image build`. Plumbing dry-run done with
  a fake ISO; nothing has run against real Windows media.
- **WP3.0 VM manager app** (2026-11-23, owner request): SwiftUI app in
  `app/` (Liquid Glass, macOS 26+), built by `scripts/build-app.sh` into
  `build/app/Seemless.app`. Kit additions: `VMManager` (one controller for
  VMs started here or elsewhere), boot settings (order, TPM on/off, firmware
  menu wait), persisted media, `BootKeys` (Escape → firmware setup, Space →
  CD prompt), restart, UEFI/TPM reset. CLI: `vm set`, `vm restart`,
  `vm media`, `vm firmware`, `vm screendump`, `vm run --firmware-setup|--cd-prompt`.
  Firmware setup and firmware wait checked by QMP screendump; app checked by
  window screenshots (stopped and running states). Nobody has clicked
  through the app yet.
- **S4 on real media** (2026-11-23, build 26300 ARM64): the unattended
  pipeline runs from a blank disk to `FIRSTBOOT_OK` in ~5 min with zero
  keystrokes. Fixed two bugs only real media could show (WinPE has no
  `findstr`; SetupComplete runs before OOBE, so the answer file must survive
  it). First DISM inventory saved. Details: `docs/spikes/S4-unattended-install.md`.
- **WP2.3 removal recipes** (2026-11-23): `seemless-default` and
  `seemless-gaming` written from the real build-26300 inventory, checked by
  `RecipeTests` against it; a real build removed 22 apps, 8 capabilities,
  2 features and imported the policies. Edge browser kept on purpose until
  links can open on the Mac (M4). `apply.cmd` recipe steps are now
  non-fatal per entry, use a DISM scratch dir, and record an after-recipe
  inventory.
- **Install profiles in the app** (2026-11-23): New VM sheet has required,
  unselected choices for install type and profile (Lean / Lean, with Xbox /
  Fat = new empty `stock` recipe) and an About Profiles popover. Checked by
  window screenshots via `SEEMLESS_OPEN=new-vm|new-vm-automatic|new-vm-about`.
- **Open in Seemless + Edge removal** (2026-11-23): Finder Open With /
  Services entry for .exe/.msi → confirm sheet → read-only `SLRUN` USB drive
  hot-plugged over QMP (`VMManager.launch`, `seemlessctl vm open`); guest
  launcher logon task installed by the image build. Lean recipes delete the
  Edge browser. Verified: hot-plug and replace against real QEMU (tests),
  Open With registration, the sheet (screenshot), and a real Lean build
  (Edge deleted, launcher task registered, FIRSTBOOT_OK, 0 warnings).
  Not verified: the launcher starting an installer in a logged-on Windows
  session (needs the licence accepted).
- **Local Windows account in the app** (2026-11-23): automatic installs
  always create a local administrator account (no Microsoft account; network
  off, online-account screens hidden, auto-logon, password in the Keychain).
  The New VM sheet now shows it and lets the person name it (default
  `Seemless`); `LocalAccountTests` pins the answer file to a local account.
- **S4 closed** (2026-11-23, owner): Lean VM rebuilt, licence accepted by
  the owner. The owner confirmed auto-logon to the local account with no
  further OOBE pages, the policies in effect, and Open in Seemless starting
  Firefox's installer in Windows. D8 decided. These were checked by the owner
  by hand; no log or screendump of them was kept.
- **WP4.1 protocol + mock agent** (2026-11-23):
  - Schema `proto/seemless.proto` covers the whole v1 catalogue from docs/06,
    plus `Error`, `Ack`, `GetGuestInfo` and `BulkOffer`.
  - Rust: `proto` crate (types generated at build time by protox + prost,
    framing, handshake) and the `protogen` dev tool.
  - Swift: generated types checked in (`scripts/gen-proto.sh`, `--check`
    runs in `check.sh`); `AgentFrame`, `AgentHandshake`, `AgentClient`
    (requests, timeouts, heartbeat, restart detection) and `MockAgent`.
  - CLI: `seemlessctl mock-agent` and `seemlessctl agent hello|info`.
  - No `protoc` is needed anywhere.
  - Golden frames in `proto/testdata/` are byte-identical from both
    languages.
  - Tests: 22 Swift (round trips against the mock, including a silent agent,
    an agent restart, an oversized frame, a garbage envelope and an
    incompatible Hello), 9 Rust; 30 repeated runs with no failure.
  - Found while testing: a chunk holding a valid frame followed by a bad one
    lost the valid frame. Both decoders now deliver it, then reset.
- **S3 display export** (2026-11-23, own session): D4 decided. `-display
  dbus` cannot run the GL device on macOS, so we build our own small backend,
  `ui/seemless`. It exports scanouts as an IOSurface ring sent as Mach send
  rights; input goes over QMP `input-send-event`.
  - Spike patch: `patches/qemu/spike-S3-ui-seemless.patch`. Viewer:
    `spikes/S3-display/`.
  - The viewer showed the firmware and the Windows desktop, and a click
    opened Start.
  - Adds +6 ms (draw on arrival) to +10 ms (display link) key→glass over
    `cocoa`.
  - The Metal (3D) scanout path is built but has not run: it needs S2's
    driver. Note: `docs/spikes/S3-display-export.md`.
- **S8 D3D12 on Vulkan** (2026-11-23, own session): verdict **patch**, with
  KosmicKrisp the better base.
  - vkd3d-proton builds natively with a small port patch.
  - Neither driver gives a device unmodified: MoltenVK 1.4.2 lacks 4 hard
    requirements, KosmicKrisp lacks 2 (patchable in vkd3d-proton).
  - With those checks bypassed: MoltenVK 461/578 tests at FL 11_0,
    KosmicKrisp 510/578 at FL 11_1, both SM 6.0; the demos render on both.
  - FL 12_0 / SM 6.x need sparse residency, int64 atomics and more.
  - Rough size: weeks to get a device, months for full feature levels.
  - Note: `docs/spikes/S8-d3d12-moltenvk.md`; build pins in
    `spikes/S8-d3d12-moltenvk/deps.lock`.
- **S2 graphics bring-up** (2026-11-23, own session, partial):
  - **The renderer ran for the first time** (UTM's v0.6 `viogpu3d` on VM
    `admfix`): Neptune with the DXMT D3D11 backend, feature level 11_1.
    DWM is GPU-accelerated, and the scanouts are shared at 1024×768.
  - **D12 confirmed in the guest:** the kernel driver loaded with no
    test-signing and no Secure Boot. UTM's drivers are Microsoft
    attestation-signed (HWCC catalog) plus EV-signed.
  - D3D12 is not available on DXMT, as expected (that is the S8 path).
- **Non-admin account fixed** (2026-11-23):
  - **Bug:** on build 26300 OOBE created the account from `<LocalAccounts>`
    but ignored `<Group>Administrators</Group>`. Checked in the guest: the
    account was in no local group, and `Administrators` held only the
    disabled built-in account. So nothing could elevate.
  - **Second bug:** the FirstLogonCommand that deletes
    `Panther\unattend.xml` (the encoded password) ran as that non-admin user
    and failed, so the file stayed on disk.
  - **Fix:** `firstboot.cmd` (SYSTEM, before OOBE) runs
    `image/guest/setup-account.ps1`. It creates the account from the
    payload disk's answer file and adds it to Administrators and Users by
    SID. It checks the membership, and reports `ERROR account` instead of
    `FIRSTBOOT_OK` on failure. It also registers a one-shot SYSTEM task that
    deletes the answer files at first logon.
  - **Answer file:** `unattend.xml` keeps AutoLogon and hides both OOBE
    account pages.
  - **Verified:** a fresh Lean build (6 min 39 s) logged
    `account Seemless ready (Administrators, Users)` and `FIRSTBOOT_OK`.
    The S2 session then checked first start in Windows (VM `admfix`):
    - no account page;
    - auto-logon;
    - `Seemless` in `BUILTIN\Administrators` (UAC asks for consent, not
      credentials);
    - `Panther\unattend.xml` deleted by `\Seemless\RemoveAnswerFile`.
  - **Found by the real builds:** Setup rewrites the passwords in Panther's
    cached copy, and `New-LocalUser` caps descriptions at 48 characters.
- **Virtio-gpu reset abort fixed** (2026-11-23):
  - **Cause:** libepoxy resolves EGL extension entry points lazily, against
    `eglGetCurrentDisplay()`. The first `eglDestroyImageKHR` can run at
    `virtio_gpu_reset` with no context current on QEMU's main thread (the
    first device reset of a cold boot), and then libepoxy aborts.
  - **First attempt (S2) was insufficient:** it made virgl's context
    current before the destroy. It passed 3 resets, but the owner's cold
    start at 23:05 aborted again. QEMU uses `virgl_egl_init_external`, where
    `egl_ctx` is NULL, so the call only released the current context.
  - **Fix:** `patches/virglrenderer/0001-egl-resolve-destroy-image-at-init.patch`
    looks up `eglDestroyImageKHR` once at init with `eglGetProcAddress` and
    destroys through that pointer. It is applied by the new idempotent
    `apply_patches` in `scripts/build-deps.sh`.
  - **Verified on `admfix`:** 4 cold boots and 10 hard resets with no abort,
    no "No provider" line and no crash report. Two runs ended in a clean
    guest power-off right after a hard reset, with no crash. The old build
    did that once too; it looks like Windows reacting to back-to-back hard
    resets, and is not investigated.
  - **Not done:** the UTM repro, skipped by the owner's choice (UTM not
    installed; root cause unambiguous).
  - The hvf reset fix (utmapp/qemu#6) is already in the pinned QEMU.
- **Zen Dock icons** (2026-11-24, owner requirement): a running Windows
  app's Dock icon must look like that app's icon. Recorded in docs/05 ("App
  identity on the Mac side") and the roadmap; WP6.8 is no longer optional.
  An interim step is designed: minimised tiles badged with the app's icon.
  Nothing is built; it needs `GetIcon` from the agent.
- **Zen bug-testing round 1** (2026-11-24, on `fw` with the mock agent, then
  a real Notepad on a fresh VM `zen1` by the owner): 11 host bugs fixed
  (owned dialogs, minimised-at-start, agent silence, Zen holding `ctl.sock`,
  frozen windows after QEMU exits, re-enter leak, and others). Following the
  owner's Notepad trial, moves are now Mac-only, live resize is unstretched,
  the guest window stays in the work area, and the Windows cursor is hidden.
  `scripts/check.sh` passed with 151 Swift tests. Results and manual checks:
  `docs/testing/seamless.md`.
- **Desktop window for exported displays** (2026-11-24, WP3.2 started; the
  owner found Show Display did nothing for a VM started with "Start without
  Window"):
  - **What it does:** Show Display on such a VM opens (or focuses) one
    titled, resizable Mac window with scanout 0 live. Pointer, buttons,
    scroll and keys go to the guest over QMP on `input.sock`, as in Zen.
    The content keeps the guest's aspect ratio. A guest resolution change
    reshapes the window. The window closes when the VM stops (QMP closes).
    A VM with QEMU's own window still gets that window brought forward.
  - Zen and the desktop window share `input.sock`, so opening one closes the
    other for that VM.
  - **Kit:** `DesktopGeometry` (`kit/.../Display/`), 7 tests.
  - **App:** `app/Seemless/Display/DesktopWindow.swift`, reusing
    `ZenRenderer`, `GuestInput` and `GuestKeyMap`.
  - New developer switches: `SEEMLESS_OPEN=display:<vm>` and
    `SEEMLESS_DISPLAY_TYPE`.
  - **Verified on `fw` (firmware, UEFI shell, 800×600):**
    - the window showed the live shell (window screenshot seen);
    - text typed through the window ran in the shell (`seemlessctl
      screenshot` seen);
    - stopping the VM closed the window.
  - **Typing was checked with synthetic `NSEvent`s sent through the
    window**, not real keystrokes. Posting CGEvents needs a permission this
    Mac does not grant.
  - **Not verified:**
    - pointer input, and a guest resolution change (the firmware does not
      change mode; the logic is unit-tested);
    - the QEMU-window fallback being brought forward. macOS kept the old
      front app when the app was launched in the background, and also when
      a script activated QEMU directly. It now yields activation first, the
      macOS 14+ pattern, but that needs a real click to check.
  - **Zen → desktop on the last window** (owner requirement, 2026-11-24):
    when the guest closes its last app window, Zen ends with no alert and
    the desktop window opens. Minimised windows still count as open, and
    there is a 300 ms debounce. Starting empty, agent loss, VM stop and Exit
    Zen don't trigger it. Kit: `ZenLastWindowWatch`, 5 tests. Verified with
    the mock agent on `fw` (docs/testing/seamless.md round 3). The handover
    now waits for the old session's QMP connection to close (no fixed sleep),
    both ways.
  - **Still to do for WP3.2:** resizing the window should change the guest
    resolution (`DisplayClient.requestSize`), the guest pointer shape,
    HiDPI, and Notepad on a booting Windows VM.
- **Zen windows behave like windows** (2026-11-24, owner request; Z5's
  host side pulled forward):
  - macOS rounded corners (16 pt) with the Mac shadow.
  - Native drag from the Windows title bar: a hover `HitTest` (cached),
    then `performDrag`, then `SetWindowRect`.
  - Native edge resize, then `SetWindowRect`.
  - A Windows minimise becomes a Dock minimise; restoring from the Dock
    sends `WindowCommand restore`.
  - Maximise follows the guest. Close (X in the guest, or Cmd-W as
    `WM_CLOSE`) closes when Windows removes the window.
  - The mock agent gained a simulated Windows window manager
    (`SimulatedWindowManager`, script `"windowManager"`).
  - 137 Swift tests.
  - **Verified on `fw`:**
    - the guest-driven sequence, with no echoed commands (after a fix);
    - rounded corners (screenshot);
    - real pointer hover producing `HitTest` requests.
  - **Not verified by me:** dragging, resizing and the shortcuts by hand.
    A playground was left running for the owner.
  - All of this follows a real Windows app only once the agent exists (Z2).
  - **Owner (2026-11-24):** good enough for now. Run a Zen bug-testing round
    once VM start-up and shutdown are reliable (the 3D-driver boot blocker)
    and the agent provides real windows.
- **Zen mode Z1 built** (2026-11-24):
  - **What it does:** each window the agent reports becomes a borderless
    Mac window (no title bar, no traffic lights) showing its crop of scanout
    0 through a Metal layer. Pointer and keys go to the guest over QMP
    `input-send-event`, in order. The Windows pointer is never drawn.
  - **Kit:** `kit/.../Zen/`, with 14 tests covering the window model (with
    untrusted-guest validation), geometry, the key map and QMP encoding.
  - **App:** `app/Seemless/Zen/`.
  - **Verified:** on the firmware VM `fw` with a mock agent, the Zen window
    showed exactly the scripted crop (screenshot seen).
  - **Not verified:** clicks and typing through the window (no UI
    automation here), and Notepad on Windows (no bootable 3D VM).
  - **Also designed:** the owner's notes. The Windows pointer is hidden and
    Mac cursor shapes follow the guest via a planned `CursorShape` message
    (Z3). The clipboard bridge is step Z3b (WP4.5).
- **App layout refined** (2026-11-24):
  - **Header:** two lines (name and controls; then status, start time and
    a "Started from Terminal" chip). The big icon is gone.
  - The status badge no longer wraps.
  - The selected sidebar icon stays visible.
  - Boot & Firmware hides its actions while the VM runs.
  - New developer switch: `SEEMLESS_OPEN=select:<vm>`.
  - Checked by window screenshots, stopped and running.
- **Zen mode designed** (2026-11-24): the owner named seamless mode "Zen
  mode": chrome-less Windows app windows on the Mac, with no Mac title bar
  or traffic lights.
  - docs/05 now holds the Zen window decisions: borderless subclass, Windows
    buttons mirrored, Mac shadow, corner masks, host-driven move.
  - It also holds a readiness table and the build order Z1–Z6. Z1 (the host
    Zen window on tier 2, driven by the mock agent) can start now, on the
    Mac alone.
  - docs/00 and the roadmap use the new name.
- **WP3.1 display backend** (2026-11-24, S3 session):
  - **QEMU patch:** `patches/qemu/0001-ui-seemless-display-backend.patch`,
    with protocol v1 documented in its header. Mach-port IOSurface ring,
    cursor, mouse and `SET_SIZE` for resize.
  - **Host side:** a SeemlessKit receiver (`kit/Sources/SeemlessKit/Display/`).
  - **New command:** `seemlessctl screenshot`.
  - **Verified on a fresh Lean VM `wp31` with the 3D driver:** the
    screenshot shows the 3D desktop where QMP `screendump` is black
    (`build/s3/shots/desktop-3d.png`, seen), and resize to 1280×800 works.
  - Agents can now see the 3D desktop.
- **S9 Steam games in the VM** (2026-11-24, own session): the VM is
  feasible as a **pseudo-prefix** that FineWine's Steam tool could pick
  instead of a Wine prefix.
  - **Chosen (owner):** shape B, a cross-VM `lsteamclient` bridge to Mac
    Steam, with no Windows Steam in the guest. The goal is a proof of
    concept and anti-cheat does not matter. Roughly 1 month to a PoC and
    3–6 months to match FineWine's bridge; the bridge halves belong in
    FineWine, which holds the Valve-licensed code.
  - **E1 done** (Portal 2): Steam passes `waitforexitandrun <exe>`;
    "playing" lasts as long as the tool's process; Stop sends SIGTERM.
  - **E5/E6 not run yet:** a throwaway build in `build/s9/root` was stopped
    part-way and deleted (owner: too many VMs at once). They will run on
    WP4.2's agent VM. Scripts are in `spikes/S9-steam/`, and the test USB
    image (redists + REKA, never committed) is `build/s9/s9-usb.img`.
  - E2–E4 are dropped: each needs Windows Steam in the guest.
  - Note: `docs/spikes/S9-steam-in-vm.md`. FineWine untouched.
- **S6 fast resume** (2026-11-23, S2's session, owner-requested): suspend
  to disk will use **guest hibernate**, not QEMU state.
  - With the 3D driver loaded, `savevm` and migrate-to-file are blocked:
    `virgl is not yet migratable`, and `nvme` and `usb-audio` are not
    migratable either.
  - QMP `stop`/`cont` works (~0.2 ms) but is lost if QEMU exits, so it
    stays for short automatic pauses.
  - Hibernate does not depend on QEMU device state, but it is **not
    validated**: agents can't see the 3D desktop, and `admfix` broke (see
    Not done).
  - docs/02 is updated. Note: `docs/spikes/S6-fast-resume.md`.
- **WP7b.0 D3D12 trigger review** (2026-11-23): **no-go on writing our own
  guest D3D12 driver**, because upstream ships one.
  - Triton has a full D3D12 DDI on `utmapp/mesa` `neptune`. That is the
    same SHA we pin as `win-umd-mesa`.
  - The v0.6 package already installed on `admfix` exports
    `OpenAdapter12`.
  - Our pinned virglrenderer loads the D3D12 backend from
    `NPT_D3D12_LIBRARY_PATH`; on Apple arm64 it defaults to DXMT, which has
    no D3D12.
  - So the D3D12 work is host-only (WP7.5): a native macOS vkd3d-proton
    dylib for that slot. Start from upstream's fork (`osy/vkd3d-proton`
    `neptune`, pinned as a candidate) plus S8's macOS patch.
  - Untested risk: D3D12 present and interop when DXGI and D3D11 come from
    DXMT but D3D12 comes from vkd3d-proton.
  - A message to UTM's maintainers is drafted in the note. **Owner
    (2026-11-24): not sending it.** The draft stays in the note, for reference.
  - Note: `docs/spikes/WP7b0-d3d12-trigger-review.md`.
- **WP5.1 guest `windows-model`** (2026-11-24, own session):
  - **What it does:** classifies top-level windows (normal, dialog, menu,
    tooltip, popup, splash or tool, or ignored and why) and turns them into
    the protocol's `Window`, `WindowSnapshot/Added/Updated/Removed` and
    `FullscreenState` messages, ready for WP4.2 to send. No proto change
    was needed.
  - **Pieces:**
    - `rules.toml` holds the per-class and per-app rules. Defaults are
      compiled in; an `/agent/rules.toml` override is read first.
    - The `WindowSource` trait stands in for the Win32 side.
    - Dump capture is `Dump::capture`.
    - `examples/dump-to-mock` writes mock-agent scripts;
      `proto/mock/office-dialogs.json` was made with it.
  - **Decisions** are in docs/05, "Classification as built":
    - an owned window's owner is its nearest mirrored ancestor;
    - a main window owned by a hidden application window is normal;
    - a splash is a frameless popup that is its process's only window;
    - an owned window takes its owner's `app_key`, so Word's dialogs group
      with Word.
  - **Acceptance:** 10 app dumps (69 windows) classify as expected. 33
    Rust tests in the crate.
  - **Cross-check:** every dump's snapshot also loads into the host's
    `ZenWindowModel` with 0 rejected, using a throwaway checker outside the
    repo.
  - **The dumps are synthetic**, written by hand (no Windows VM). Replace
    them with captures when the agent runs (`tests/data/README.md`).
  - **Not built:** the Win32 enumerator and event hook. They need the
    Windows target, and they go with the session agent.
- **Preview 1 P2: first run and desktop mode** (2026-11-24, own session):
  - **First run (WP3.4):** an empty library opens a welcome flow
    (`app/Seemless/WelcomeView.swift`): requirements (`FirstRun`, kit), the
    user's own ISO with Microsoft's download link, a profile, then the
    automatic install with staged progress (`ImageBuilder.Phase`) and the
    guest drivers (`GuestDrivers.locate`). Windows then starts in its
    desktop window with a bar saying the person accepts Microsoft's licence
    there. The app never accepts it: the New VM sheet's "accept now" toggle
    is gone.
  - **Desktop mode (WP3.2):** `KeyboardTranslator` (Mac style default: ⌘
    shortcuts → Ctrl, ⌘ alone → Start; PC style; macOS shortcuts reserved),
    resize/full screen → guest resolution over `SET_SIZE`, Display menu
    (Send Keys incl. Ctrl-Alt-Delete, full screen, scaling, keyboard
    style). Start now always uses the exported display; QEMU's window is
    "Start in QEMU Window".
  - **WP3.5 part:** audio was already `usb-audio` on CoreAudio, always on.
    Scaling is Standard (default) or Retina per VM; Windows does not pick
    200 % by itself, so Retina waits for the agent's DPI (WP4.4).
  - **Verified** on VM "Windows 11" (`build/p2/root`), built by the app's
    flow (`FIRSTBOOT_OK`, 3D driver): licence accepted by the owner in the
    window; Notepad typing with ⌘A; 1280×720 window → guest 1280×720;
    Retina full screen → 3024×1898; Ctrl-Alt-Delete; Windows' default
    playback device is the USB audio device, and the owner heard the speaker
    test on the Mac (audio pass). Results:
    `docs/testing/desktop-mode.md`.
  - **Not verified by a person:** clicking through the welcome flow (run by
    developer switches), dragging to resize, the menus, the PC style. The
    guest pointer shape is not drawn (the Mac pointer is shown).
  - 24 new Swift tests; `scripts/check.sh` passes (192 Swift tests).
- FAT image operations (`hdiutil`/`diskutil`) are serialised: in parallel
  they made tests 4-10x slower.
- 163 Swift tests and 9 Rust tests, all passing (`scripts/check.sh`, 2026-11-24).
- Upstream research: UTM 5.0's Neptune/Triton DirectX stack and Tiny11
  Builder 0.2.0 state (see `11-references.md`).

- **P1 self-contained, signed app** (2026-11-24, WP8.1/8.2/8.5, partial):
  - `scripts/package-release.sh` builds `build/release/Seemless.app` (QEMU,
    qemu-img, swtpm, render server and `seemlessctl` in `Helpers/`, 34
    dylibs in `Frameworks/` with `@rpath` names, firmware in
    `Resources/qemu`, image assets, licences), a dmg and a zip. An `otool`
    audit (`scripts/release/audit-bundle.sh`) fails the build on any path
    outside the bundle. Signing is inside-out with the hardened runtime;
    QEMU gets only `com.apple.security.hypervisor` (no JIT needed).
    Notarization runs when the owner sets `SEEMLESS_SIGN_IDENTITY` and
    `SEEMLESS_NOTARY_PROFILE`. Runbook and the owner's one-time setup:
    `docs/release.md`.
  - `HostStack` has an app-bundle layout. `locate()` prefers the
    enclosing bundle over `build/prefix`. `ImageAssets` does the same.
  - Licences: notices generated from `THIRD_PARTY.md` (new "Shipped in
    Seemless.app" table) and Homebrew's metadata; `source-archive.sh`
    builds the source offer from the pinned SHAs, submodules, Homebrew
    tarballs and `patches/`.
  - **Verified:** the bundle copied out of the repository ran under
    `sandbox-exec` with `build/prefix` and `/opt/homebrew` unreadable.
    Its own `seemlessctl` booted two firmware VMs to the UEFI shell
    (screendumps checked). ANGLE, virglrenderer and SDL3 loaded from
    `Contents/Frameworks`, and nothing was mapped from the prefix or
    Homebrew. The app found the bundled stack (window screenshot). Nobody
    clicked Start in the release app.
  - **Not done:** releasable on macOS 26: 14 Homebrew dylibs need macOS 27
    (docs/10 L1; the audit fails without `--allow-newer-minos`). Developer
    ID signing and notarization have not run (they need the owner's
    identity). Licence findings L1–L6 in docs/10 need the owner.

## Not done

- **Resolved: Windows VMs with the 3D driver stopped booting** (`admfix`,
  `wp31`). Cause found in S6b (`docs/spikes/S6b-hibernate-resume-crash.md`):
  Fast Startup turns every shutdown into a hibernate. The resume with
  viogpu3d faults on the virtio-gpu blob window, Windows' handler reads
  `ERRIDR_EL1`, and QEMU's HVF backend has no handler for it, so the guest
  bugchecks (0x1E). Sometimes the next boot hangs in firmware, and after a
  forced power-off it goes to Startup Repair.
  - **Fix:** `firstboot.cmd` sets `HiberbootEnabled = 0` and the build fails
    if it isn't set.
  - **Confirmed:** WP7.5's fresh VM `wp75` shut down and restarted cleanly
    three times (2026-11-24).
  - **Still broken:** guest hibernate with viogpu3d, which was S6's chosen
    suspend method, so suspend stays out of the preview.
- **All VMs deleted** (owner, 2026-11-24): the app's "Windows 11" (Lean),
  `s2`, `fw`, `wp31`, `zen1`, and the `bootfix` VMs `a1`, `n1`, `r1`, about
  52 GB. VMs are re-created as new work needs them, so the non-admin
  account bug in older VMs is gone with them.
- **Checked off by the owner** (2026-11-24), not run: Fire Strike, S6's
  hibernate-resume check, the Zen Z1 Notepad acceptance, and the postponed
  Zen bug-testing round. They are no longer tracked as next steps.
- **The reset fix stays local** (owner, 2026-11-24): `patches/virglrenderer/0001`
  is not sent upstream. Patches the project needs are kept in `patches/`
  for this project only. A guest-initiated restart (Start ▸ Restart) was
  not separately tested; `vm restart` hits the same `virtio_gpu_reset`
  path.
- **Agents can't see the 3D desktop:** `vm screendump` returns black once
  the WDDM driver owns the display (the output is a GPU texture). The
  IOSurface scanout dump (`seemlessctl screenshot`, from S3's backend) is
  needed.
- S2 not finished: the driver was not loaded, and dxdiag and Fire Strike were
  not run, so virglrenderer/Neptune still have never run. Blocked by the
  account bug, then by the usage limit. Resume steps: `docs/spikes/S2-windows-graphics.md`.
- Idle RAM and disk use, stock vs `seemless-default`, not measured (G4/WP2.5).
- The agent protocol has only run against the mock: no Rust agent exists
  yet, and nothing has crossed virtio-serial (WP4.2). The bulk channel and
  `WindowModel` are not started.
- Suspend/resume-from-disk (S6), sealing a golden image, guest agent (M4)
  not started. App: VM manager, Zen preview and a first desktop window
  (WP3.2 ◐: no resize → guest resolution yet). The helper, onboarding flow
  and menu bar extra are not started.
- App actions that start a VM from the app (buttons, sheets) were not
  clicked in this session: they call the same `VMManager` paths the tests
  cover, but the UI wiring itself is unverified by hand.
- No vendored sources (S1 uses build-time checkouts in `build/src`).
- virglrenderer, Venus and Neptune have not run: QEMU starts the renderer
  only when a guest driver talks to it (S2).
- CI workflow written but never run on GitHub.
- Windows-target build of the agent not checked (target not installed).
- Spikes S2–S8 not run. Every "Provisional" decision in
  `01-architecture.md` is unproven.
- Nothing in the plan has been tested on hardware.

## Next

Owner's order (2026-11-24): WP4.2, WP5.1 and WP7.5 run now, in parallel
sessions, alongside S9's experiments. The Zen steps after the agent follow.
Open questions come last.

1. WP4.2: the Rust service and session agent over vioserial; acceptance
   `seemlessctl agent info` against a real VM. It needs the Windows target
   and cargo-xwin, whose first build asks the owner to accept Microsoft's
   CRT/SDK licence.
2. WP5.1 (guest `windows-model`) and the host `WindowModel`: both can be
   driven by the mock agent now.
3. WP7.5, D3D12 (◐ 2026-11-24; note `docs/spikes/WP7.5-d3d12-host-backend.md`):
   - **Done:** vkd3d-proton (`osy` `neptune`) and MoltenVK v1.4.2 built
     from source by `build-deps.sh moltenvk vkd3d`, with H1–H4 patched in
     `patches/vkd3d-proton-npt/` and `patches/moltenvk/` (no capability
     bypass); the launcher sets `NPT_D3D12_LIBRARY_PATH` for DXMT.
   - **Ladder:** host rungs 1–3 pass (FL 11_0, SM 6.0). In a fresh guest
     (`build/wp75/root`), rungs 1–3 pass with DXBC; rung 3's frame equals
     the host reference byte for byte.
   - **Open:** DXIL in the guest. Triton advertises SM 5.1 for a DXMT
     capset, and with `CAP_DXIL` forced it claims 12_1 and device creation
     fails: needs a Triton change (WP4.6) or more host features. Then
     shared textures/heap import for vkd3d-proton (rung 4), FL 12_0 / SM 6.x
     work, and pointing Venus at the same MoltenVK.
4. S9 phase 0, in parallel: experiments E5 (virtio-serial round trip on a
   third port) and E6 (VC++ and DirectX redists, plus a D3D11 x64 game, on
   build 26300). E2–E4 stay dropped: each installs Windows Steam in the
   guest, which the owner ruled out (S9 decision 1).
5. After WP4.2 (Zen): Z2 real window rectangles; Z3 input, focus, cursor
   shapes and the clipboard (Z3b, WP4.5); Z4 tier 1 atlas (S5, WP5.4); Z5
   window life and transients (with the minimised Dock tile's app-icon
   badge); Z6 per-app Dock icon, name and Cmd-Tab entry (WP6.8). Then M6
   and M7.
6. **Goal set by the owner (2026-11-24): Preview 1, a public GitHub release**
   with desktop mode and an experimental Zen mode. Its scope, order and
   owner gates are in `docs/09-roadmap.md` ("Preview 1"). From now on,
   that list decides what runs next.
7. **Last, but before Preview 1 ships:** the open questions in
   `10-risks-licensing.md` (owner, 2026-11-24). Q10 is answered: MIT for
   our own code, upstream projects keep their own licences, and no ISO
   distribution. Still blocking a public release: Q11 (name), Q12 (agent
   CRT redistribution) and Q13 (how users get the guest drivers).

## Learned

- This Mac: M3, 4 performance + 4 efficiency cores, 24 GB, macOS 27.3,
  Xcode 27.3 beta, Swift 6.4.2.
- virglrenderer defaults to **D3DMetal** when `NPT_BACKEND` is unset; the
  launcher always sets it (`dxmt` by default).
- QEMU serves one client per QMP monitor; we run two (owner + controllers).
- Homebrew's Rust (1.100.0) shadows rustup's on PATH. Seemless scripts call
  `~/.cargo/bin/cargo` directly. Fix permanently by reordering PATH or
  `brew uninstall rust`.
- cargo-xwin's first Windows build downloads Microsoft's CRT/SDK and requires
  accepting Microsoft's licence: that is the owner's decision.
- UTM's build notes pin ANGLE to WebKit commit `6a7f464…` and need LLVM 15,
  pkg-config and the Metal toolchain (all checked by `bootstrap.sh`).

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
| 2026-11-23 | WP0.1 | Scaffolding done; acceptance check passes (exit 0) |
| 2026-11-23 | S1 (in progress) | Owner decision: macOS 26 minimum (D10). Package, build scripts (deployment target 26.0), CI and docs updated |
| 2026-11-23 | S1 | Host stack builds and smoke-boots to firmware; 9 deviations recorded; renderer runtime unproven until S2 |
| 2026-11-23 | M1 + M2 (ISO-free) | VM runtime and image pipeline built; 53 tests; bugs found and fixed: blocking socket reads starving the concurrency pool, uncancellable waits, single-client QMP, recursive state description |
| 2026-11-23 | WP3.0 | VM manager app + `VMManager`, boot/firmware settings, media; 64 tests; firmware menu and wait verified by screendump |
| 2026-11-23 | S4 (partial) | Pipeline runs unattended to FIRSTBOOT_OK in ~5 min; fixed missing-findstr disk detection and pre-OOBE answer-file deletion; inventory saved |
| 2026-11-23 | WP2.3 | Default and gaming recipes from real inventory; verified by an after-recipe inventory; fixed a missing batch label that silently skipped recipe steps |
| 2026-11-23 | WP3.0 | Install profiles (Lean / Lean, with Xbox / Fat), required choices, About popover |
| 2026-11-23 | WP3.0 | Open in Seemless (installer hot-plug + guest launcher); lean recipes remove Edge |
| 2026-11-23 | S4 | Closed by the owner's check (auto-logon, policies, Open in Seemless); D8 decided |
| 2026-11-23 | S3 | D4 decided: own `ui/seemless` backend (dbus can't run GL on macOS); +6–10 ms over cocoa; Metal path unrun |
| 2026-11-23 | S8 | Verdict patch; KosmicKrisp the better base (510/578 vs 461/578 at FL 11_x) |
| 2026-11-23 | S2 (partial) | D12: UTM drivers attestation-signed, no test-signing; blocked by non-admin account bug |
| 2026-11-23 | Image fix | Account created as admin by SYSTEM before OOBE (OOBE ignored the Administrators group on 26300); FIRSTBOOT_OK on a fresh build; OOBE half awaits the owner |
| 2026-11-23 | S2 + main | Virtio-gpu reset abort fixed: first patch failed on a cold start (owner's crash report); revised patch resolves eglDestroyImageKHR at init; 4 cold boots + 10 resets clean |
| 2026-11-23 | D3a | Owner chose MoltenVK as the D3D12 Vulkan driver (S8 had recommended KosmicKrisp) |
| 2026-11-24 | WP3.2 (start) | Show Display opens a live desktop window for exported displays (fw: view and typing checked; window closes on VM stop); QEMU-window fallback kept. Zen → desktop when the last app window closes (mock-agent checked) |
| 2026-11-24 | Zen Z1 | Chrome-less per-window crop windows + QMP input, mock-agent driven; crop verified on fw; app layout refined |
| 2026-11-24 | WP3.1 | ui/seemless display backend patch + SeemlessKit receiver + `seemlessctl screenshot`; 3D desktop visible to agents (VM wp31) |
| 2026-11-24 | S9 | Steam-in-VM feasibility: pseudo-prefix design, shape A (Steam in VM) / B (cross-VM lsteamclient); experiments E1–E4 await owner |
| 2026-11-24 | S9 | Shape B chosen, E2–E4 dropped; E1 done (argv, lifetime = playing, Stop = SIGTERM); E5/E6 build stopped and deleted at owner's request, to run on WP4.2's VM |
| 2026-11-23 | S6 | Suspend = guest hibernate (QEMU snapshot/migrate blocked by virgl, nvme, usb-audio); hibernate not yet validated; admfix boot-damaged by repeated hard resets |
| 2026-11-23 | WP7b.0 | Trigger not fired: upstream Triton ships a D3D12 UMD; D3D12 work is host-only (WP7.5, vkd3d-proton dylib) |
| 2026-11-23 | S2 (partial) | Renderer runs (DXMT D3D11, FL 11_1, DWM accelerated); D12 confirmed in guest; QEMU aborts on virtio-gpu reset (eglDestroyImageKHR unresolved) |
| 2026-11-23 | WP4.1 | Protocol, Swift/Rust codegen without protoc, framing, handshake, AgentClient, mock agent; 22 Swift + 9 Rust tests |
| 2026-11-24 | WP5.1 | `windows-model`: classification, rules.toml, tracker emitting protocol messages; 10 synthetic app dumps classify as expected (33 tests); Win32 enumerator not built |
| 2026-11-24 | WP7.5 (◐) | vkd3d-proton + MoltenVK built from source with H1–H4 patches; `NPT_D3D12_LIBRARY_PATH` wired; ladder rungs 1–3 pass on host and in a guest with DXBC (rung 3 = host reference); guest DXIL blocked by Triton's SM 5.1 caps |
| 2026-11-24 | P2 (WP3.4, WP3.2, WP3.5 part) | First-run flow builds and starts Windows with the 3D driver (licence accepted by the owner in the window); Notepad typing, resize → guest resolution, full screen, Ctrl-Alt-Delete verified by screenshots; audio device present in Windows and heard by the owner |
| 2026-11-24 | P1 (◐) | Release packaging: self-contained app, otool audit, hardened-runtime signing (ad-hoc here), notices, source offer; relocated app boots firmware with no build/prefix or Homebrew; blocked for macOS 26 by Homebrew libraries built for 27 (docs/10 L1) |
