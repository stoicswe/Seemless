# S9 — Steam games in the VM (feasibility, notes only)

Date: 2026-11-24. Status: **desk spike + E1**. No product code was changed in
either repository. Nothing was downloaded and no one signed in. For E1 the
owner picked a temporary tool for Portal 2 in Steam (Q1). The evidence is source code, the Mac Steam client's own
logs on this machine (read only), and web sources (listed at the end). Every
claim below is marked:

- **[seen]**: observed on this Mac or in source code;
- **[doc]**: vendor documentation;
- **[reported]**: community reports only;
- **[unverified]**: inferred; needs the experiment named.

## Question

Can a Steam compatibility tool hand a Windows game to the Seemless VM? The
tool would be like the one FineWine already installs
(`finewine-proton`), and the game would be one the **Mac** Steam client
installed. In the VM the game would get real Windows, the D3D11/D3D12 stack,
and kernel drivers. It would not need Wine.

## Owner decisions (2026-11-24)

1. **The VM is a runtime environment, not a second Steam.** The goal is the
   VM as an alternative **pseudo-prefix** that FineWine's Steam tool can pick
   per game, next to a Wine prefix. **No Windows Steam client runs in the
   guest.** The game's Steamworks calls cross the VM boundary to the Mac
   Steam client through a **cross-VM bridge** (shape B, Q4). Shape A
   (Windows Steam in the VM) was analysed first and is **not chosen**. Its
   findings are kept in Q2/Q3 for the record.
2. **Proof of concept first.** Show it can be done; parity comes later.
3. **Anti-cheat does not matter** for this. Q5 is kept as background only.
4. **FineWine already has the Steamworks SDK tooling** (Valve's
   `lsteamclient` generator and 92 SDK header sets). The work is writing the
   bridge halves, not acquiring tooling.
5. **Library sharing is expected to work.** The owner has done library
   moves before. With no Windows Steam in the guest, it is simpler still:
   the game only has to be readable at a drive path (Q2).
6. **Seemless can carry its own cross-VM channels.** We build our own QEMU,
   so new ports or devices are allowed. The proof of concept does not need
   any (see "Transport").
7. **Open research the owner added:**
   - installing a game's **dependencies** into the VM on demand ("Game
     dependencies");
   - **network** access for games ("Network").

## Verdict

**Feasible as a proof of concept.**

- **The prefix maps cleanly** onto Seemless:
  - a VM (later, a per-game overlay over the sealed golden image, docs/02);
  - the game read from a shared library folder;
  - a launch with an exit event.
- **"Steam knows what is running and when"** is solved on the Mac side, not
  in the guest:
  - `seemlessctl steam-run` starts a **Mac proxy process** that loads Mac
    Steam's `steamclient.dylib` for the app id.
  - Mac Steam tracks the tool's script and every process that connects to
    it (Q1, seen in its logs). So the game shows as playing for as long as
    the script and proxy live.
  - The proxy exits when the guest reports the game's exit. Steam's Stop
    button reaches the guest as a terminate.
- **The bridge** forwards each Steamworks call from a stand-in
  `steamclient64.dll` in the guest to the proxy, and returns the results and
  callbacks.
  - It is FineWine's code, generated from Valve's `lsteamclient` tree with a
    serialising back end instead of Wine unix calls.
  - On real Windows no loader patch is needed: the
    `HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64` registry key
    points `steam_api64.dll` at our DLL.
  - Estimate: about 4 weeks to a proof of concept, 3–6 months to match
    FineWine's in-process bridge (Q4).
- **Seemless's part is small and generic:**
  - a byte channel between the guest and a Mac socket;
  - launching a game and reporting its exit;
  - shared folders;
  - dependency installs and network.
  - The proof of concept can run **before the WP4.2 agent exists** (see
    "Proof-of-concept plan").
- **Lost compared with Windows Steam:** the Steam overlay and VAC (the same
  as Proton). Steam Cloud auto-saves need mirroring (Q3).

## The VM as a pseudo-prefix

### FineWine's prefix model, mapped to Seemless

| FineWine prefix concept (`SteamPlay.swift`) | VM equivalent | Exists? |
|---|---|---|
| `prepareSteamPrefix`: find the prefix by `steamAppID` or create one named after the game | Find or create a **per-game VM**. Its `system.qcow2` is an overlay on the sealed `base.qcow2` (docs/02), so creation is near-instant and costs only the per-game difference. The app id is stored in the VM's config | Overlay model and `vm create` exist. Sealing a golden image is not started. Needs an app-id field |
| Runtime (Wine build) chosen per prefix | Golden image (Windows build + recipe) + guest tools version | Image pipeline exists (M2). Tools ISO is M4 |
| `createPrefix` "takes about a minute" | `vm create` from the base: seconds. First boot of a new overlay: a normal Windows boot (~30–60 s [unverified]) | Measure in phase 1 |
| Prefix settings (DPI, Windows version, DLL overrides) | VM settings (`vm set`: CPUs, RAM, display) + guest settings applied by the agent (`SetHostInfo`) | Partly (`vm set` exists, agent is WP4.2) |
| `stageSteamBridge`: copy the bridge + Valve files into the prefix | Copy FineWine's guest helper + stand-in `steamclient64.dll` into the VM (from a share, or baked into the golden image). No Valve client files are needed in the guest, because the real client is on the Mac | New (FineWine) |
| Game files live in Mac Steam's library; the prefix only sees them through `Z:` | The same: the library is an S7 share, mounted as a drive letter. **The VM disk never holds the game** (except with the import-copy option) | S7 not run |
| `steamLaunchPlan` + `runner.start`, waits for exit | `steam-run` → agent `Launch` → `ProcessExited` | Needs Launch handle + exit event |
| `wineserver -w` (wait for everything the game started) | The guest helper waits until the game's process tree is gone (a Windows job object) | New, in the guest |
| Stop watcher: `wineserver -k` when Steam's Stop kills the script | SIGTERM → `Terminate { launch_id }` → close, then kill | New |
| Per-prefix log file | `vms/<name>/logs/` (QEMU) + agent log | QEMU logs exist |
| Delete prefix | Delete the VM (overlay only; base and library untouched) | `vm delete` exists |
| "Reset" a broken prefix | `disk reset` = recreate the overlay | Exists |

### One VM per game, or one shared VM?

There is no Steam in the guest, so there is no sign-in to share. The choice
is only about isolation against start-up cost and disk.

- **One shared VM (proof of concept):**
  - one Windows for all games;
  - redistributables installed once (the `HasRunKey` keys skip repeats);
  - the same as one big Wine prefix, and the fastest to build.
- **Per-game overlay (true pseudo-prefix, later):**
  - `base.qcow2` → `game-<appid>.qcow2`;
  - isolation like Wine prefixes: one game's redistributables, registry keys
    and launcher junk cannot break another game;
  - reset per game, and cheap on disk;
  - cost: each game boots its own Windows, and common runtimes are
    reinstalled per overlay unless they are baked into the base ("Game
    dependencies" point 4).
- **Layered**, if per-game overlays prove expensive:
  - `base.qcow2` → `runtimes.qcow2` (common redistributables, guest helper)
    → `game-<appid>.qcow2`;
  - qcow2 backing chains support this;
  - the middle layer is frozen once games depend on it.

### What it costs compared with a Wine prefix

| | Wine prefix | VM pseudo-prefix |
|---|---|---|
| Start | Process start, seconds | Cold boot 30–60 s [unverified]; resume from hibernate is unvalidated (S6); QMP pause/resume ~0.2 ms only while QEMU stays up |
| RAM | The game's own | Game + Windows (~2–3 GB idle [unverified], G4 unmeasured) + QEMU/renderer; docs/02 default 8 GiB |
| Several at once | Yes | Realistically one VM at a time on a 24 GB Mac |
| Disk | Prefix ~1 GB | Overlay grows with the game's installs, plus a Windows update churn per overlay unless updates are frozen in the base |
| Graphics | D3DMetal/DXMT in-process | Same DXMT through virtio-gpu (S2: FL 11_1), plus a guest↔host hop; D3D12 via WP7.5 |
| Compatibility | Wine's API gaps | Real Windows: launchers, .NET, kernel drivers (ARM64 only), installers all behave natively; x64 code runs under Prism |

So the VM prefix is the **heavier, more compatible** option, and FineWine
should offer it per game when Wine fails, not by default.

To make it feel like a prefix, keep one VM warm: paused or hibernated after
a game ends, with an idle timeout. Then the second launch is close to
instant. That needs S6's hibernate validated, or the user accepting a
paused VM's RAM.

## Transport: how bytes cross the VM

What the pinned QEMU build offers today (probed on
`build/prefix/bin/qemu-system-aarch64`, 2026-11-24) [seen]:

- `virtserialport` / `virtconsole` exist, and Seemless already uses two
  ports (`agent`, `bulk`, `QEMUCommand.swift:229-232`).
- User networking (slirp) exists and is the default (`VMConfig.network =
  .user`), so `guestfwd` and `hostfwd` are available. `vmnet-shared` is
  also in the build.
- `vhost-vsock-pci` and `ivshmem-plain` are **not** built.

| Option | Guest side | Host side | QEMU change | Fit |
|---|---|---|---|---|
| **A third `virtserialport`, `seemless.steam`** | The guest DLL or helper opens the port (vioserial exposes named ports as `\\.\Global\<name>` [unverified on our driver build]) | Unix socket chardev in the VM's run folder; the proxy connects | None (one `-device` line) | **Proof of concept.** One stream per port, so one game at a time. Independent of the network mode |
| Over the agent (WP4.2): opaque `StreamOpen/StreamData` frames multiplexed on the control or bulk port | Named pipe to the session agent | `AgentClient` hands frames to the proxy socket | None | **Product.** Many streams, capability-gated (`stream.v1`), validated like every agent message. Needs WP4.2 |
| `guestfwd` (slirp): guest TCP to `10.0.2.100:<port>` goes to a host chardev | Plain Winsock | Unix socket or command | None | Easiest guest code, but tied to `.user` networking and one connection per rule. Fallback |
| `ivshmem` or a custom shared-memory device | Needs a guest driver | Shared memory + a doorbell | Patch or enable the device | Only if per-call latency proves too high (measure first; CLAUDE.md: keep QEMU patches small) |

**Latency is the open number.** Games call `SteamAPI_RunCallbacks` every
frame, and some call Steam Input or `ISteamUtils` many times per frame.

- E5 measures a virtio-serial round trip (echo over the third port, p50/p99
  for 64 B and 4 KiB).
- Below ~100 µs, one round trip per call is fine for a proof of concept.
  Above it, batch per frame and cache pure getters before touching QEMU.

## Game dependencies (owner's research point)

Windows Steam installs each game's redistributables on first launch. With no
Windows Steam in the guest, Seemless has to do this itself. What Mac Steam
already does, seen on this Mac:

- It **downloads the shared redistributables** for Windows games under a
  forced tool: `steamapps/common/Steamworks Shared/_CommonRedist/` holds
  `DirectX/Jun2010` and `vcredist/{2012,2019,2022}` (app 228980,
  "Steamworks Common Redistributables", is in the manifests) [seen].
- Games ship an **`installscript.vdf`** in their folder.
  - Example: The Outlast Trials has a `"Run Process"` entry with
    `"process 1"`, `"command 1"` and a `"HasRunKey"` under
    `HKLM\Software\Valve\Steam\Apps\<appid>`. Windows Steam runs it once
    and records it under that key [seen].
  - Scripts are signed (`kvsignatures`). We only read them; we never need
    to re-sign.
- The app's `appinfo` also lists the depots and redistributables it depends
  on (e.g. the 228980 depots). FineWine/NotProton already read
  `appcache/appinfo.vdf` (NotProton's `appinfo` tool) [seen].
- On Linux, Steam runs install scripts through the compat tool itself
  (`iscriptevaluator.exe` with the `run` verb) [reported]. The Mac client
  launched nothing with `run` (Q1, E1), and no `legacycompat/` folder or
  `iscriptevaluator` trace exists on this Mac [seen]. Do not rely on Mac
  Steam to do it.

Proposed design (guest-side "first run" step, owned by Seemless because it
is generic Windows work):

1. **Inputs** from `steam-run`:
   - the game's `installscript*.vdf` (Windows one, not `_osx`);
   - the redist depots named in `appinfo`;
   - the `_CommonRedist` paths on the share.
   - Parsing Valve's text format is plain data, not Valve code: FineWine
     already parses it (`SteamPlay.swift:107`), and Seemless needs its own
     small parser.
2. **Guest runner** ("deps" step before launch):
   - for each `Run Process` entry, check its `HasRunKey` in the guest
     registry; if absent, run `process N` with `command N` from the share,
     elevated;
   - write the key on exit code 0 (or on the documented "already
     installed" codes);
   - also run `Run Process` entries for `_CommonRedist`;
   - **per VM, idempotent**: the same keys Windows Steam uses, so a run is
     skipped next time.
3. **Catalogue fallback** for games that need something Steam does not list:
   - examples: .NET Framework 3.5 (a Windows feature: DISM, needs the source
     or Windows Update), .NET 6/8 desktop runtimes, XNA 4, PhysX legacy,
     OpenAL, and newer VC++ than `_CommonRedist` has;
   - a small manifest in Seemless (name, detection rule, official download
     URL, SHA-256, silent switches) fetched **at runtime from the vendor**,
     never bundled (CLAUDE.md: no Microsoft tools in the repo or app);
   - winget is an alternative where present; it needs network and Store
     policy allowing it;
   - per game, FineWine can pass extra package names, like winetricks verbs.
4. **Where the installs live:**
   - shared VM: once for every game;
   - per-game overlays: in the game's overlay;
   - common runtimes (VC++ 2015–2022, DirectX Jun2010) are worth baking
     into the **golden image**, which the `stock`/`seemless-gaming` recipes
     can grow, so most games need nothing at first launch.
5. **ARM64 specifics** [unverified, needs E6]:
   - x64 games under Prism need the **x64** VC++ runtime installed beside
     the ARM64 one (`vc_redist.x64.exe` installs on Windows ARM64);
   - DirectX Jun2010's `DXSETUP.exe` installs the x86/x64 `d3dx9/10/11`
     and XAudio 2.7 DLLs;
   - anything with a **kernel driver** in its script fails on ARM64 (e.g.
     the `EasyAntiCheat_EOS_Setup.exe` entry above). The runner should log
     it and continue, not block the launch.
6. **Untrusted inputs:** install scripts come from the game's folder. Run
   only `process` paths that resolve inside the share, or inside the
   `_CommonRedist` folder, after symlink resolution. Only the runner writes
   registry keys; the script's own "registry" sections are applied only for
   `HKLM\Software\Valve\Steam\Apps\<appid>` and the game's own keys.

Seemless already plans `/redist/` on the tools ISO "if licence allows
bundling; else fetched by winget at first boot" (docs/06). This research
replaces that with the runtime-fetch catalogue above.

## Network (owner's research point)

The VM already has network modes (`VMConfig.NetworkMode`, docs/02):

- `.user` (slirp, the **default**, outbound NAT and loopback-only
  `hostfwd` port forwards);
- `.vmnetShared` (needs root or the `com.apple.vm.networking` entitlement);
- `.none` (image builds only, docs/03).

Installs run with no network (docs/03). A VM made for games must be
switched to `.user` or `.vmnetShared` after setup [seen in code].

What games need, and where the traffic goes in this design:

| Traffic | Path | Works on slirp? |
|---|---|---|
| Steamworks calls, including `ISteamNetworkingSockets`/`Messages`, lobbies, Steam Datagram Relay, P2P via Steam | **Over the bridge**: sent by the Mac `steamclient.dylib`, so from the Mac's own network stack | n/a, not guest network |
| Game's own sockets: HTTP(S), login servers, dedicated servers (TCP/UDP outbound) | Guest → virtio-net → slirp NAT → Mac | Yes, outbound TCP and UDP [doc, QEMU] |
| Inbound connections (hosting a listen server, direct P2P without Steam relay) | Needs a port forward | Only via `hostfwd` (today bound to 127.0.0.1, `QEMUCommand.swift:217`), so it would need a LAN bind option, or `vmnet-shared`/bridged |
| LAN discovery (UDP broadcast) | Broadcast on the guest subnet | No: slirp does not pass broadcast to the LAN. Needs vmnet bridged/shared |
| ICMP ping (some launchers' server lists) | | Limited on slirp [reported] |

What to do:

- **Proof of concept:** `.user` is enough. Steam multiplayer goes over the
  bridge anyway.
- **Later:**
  - a "Game network" setting: `.user` (default), or `vmnet-shared` once the
    entitlement question in docs/02 is settled;
  - per-game inbound port forwards that FineWine can request, bound to the
    LAN only when the user agrees;
  - measure slirp's latency and throughput with `seemlessctl bench`
    (docs/08 has iperf3).
- **Safety:** the guest is untrusted, so inbound forwards stay off by
  default, and LAN binds need an explicit user choice.

## Q1. What Steam passes to the tool

### The command line [seen]

FineWine's tool declares `"commandline" "/run %verb%"` (version 2 manifest,
`SteamPlay.swift:166`). The Mac client's `logs/compat_log.txt` records the
resolved prefix at every launch:

```
[2026-11-23 17:33:17] StartSession: appID 4162040 session d4156ba694fbc7d
[2026-11-23 17:33:19] Command prefix for tool 0 "FineWine" set to: "'…/compatibilitytools.d/finewine-proton/.'/run waitforexitandrun ".
[2026-11-23 17:37:20] OnAppLifetimeNotification: release session(s) for appID 4162040
```

`logs/gameprocess_log.txt` shows the full command line, which is the verb
followed by the game's executable as a Mac path:

```
AppID 4162040 adding PID 86640 as a tracked process "'…/finewine-proton/.'/run waitforexitandrun  '/Users/…/Steam/steamapps/common/Zenless Zone Zero/HYP.exe'"
```

So argv is `run <verb> <absolute Mac path to the .exe> [game arguments…]`.
FineWine's parser assumes exactly this (`SteamRun.parse`, `SteamPlay.swift:441`).

### Verbs

- **`waitforexitandrun`** [seen]:
  - every FineWine game launch in the logs (Portal 2, Endfield, ZZZ) used
    it;
  - so did the E1 launch (Portal 2, 2026-11-24).
- **`run`** [seen, corrected by E1]:
  - At every client start, Steam logs a `Command prefix … run run` line
    for **each** installed tool (`compat_log.txt`, 09:51:10, 2026-11-24).
    That is a default prefix Steam works out ahead of time, not a launch.
    The earlier NotProton line (2026-11-23 17:08:47) is the same kind of
    line after a session start that was released at once.
  - No tool on this Mac has been seen *launched* with `run`.
  - On Linux, Proton gets `run` for steps that do not wait for earlier ones
    (install scripts) [reported, Proton].
- **`getcompatpath`** [seen in scripts, not observed by E1]: both FineWine's
  and NotProton's `run` scripts answer it with `$STEAM_COMPAT_DATA_PATH`
  and exit. E1's tool also handled it, but Steam did not ask during the E1
  launch.
- A Seemless tool must:
  - treat `waitforexitandrun` as "the game: block until it ends";
  - treat `run` as "start and wait too", the simplest safe choice;
  - answer `getcompatpath`;
  - exit 0 on anything else.

### E1 result: what Mac Steam passes (2026-11-24) [seen]

A throwaway tool `seemless-e1-envdump` (owner's OK) recorded one Portal 2
launch. Its `run` dumped argv and the environment, started no game, and
exited after 90 s.

- **Launch:**
  - argv: `waitforexitandrun`, `…/steamapps/common/Portal 2/portal2.exe`,
    `-game`, `portal2`, `-steam`. The game's own launch arguments (from
    `appinfo`) follow the `.exe`.
  - The parent is `steam_osx`, and the cwd is the **game folder**.
  - There is no tty, and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
- **"Playing" = script lifetime, confirmed:**
  - `gameprocess_log.txt`: `09:51:36 AppID 620 adding PID 90059 as a
    tracked process`.
  - Then `09:53:11 no longer tracking PID 90059, exit code 0` and
    `Remove 620 from running list`. `compat_log.txt` released the session
    at the same second.
  - The script started no other process, and Steam tracked nothing else.

Environment Mac Steam set (Steam client version 1795048523). Values
containing account data are described, not quoted.

| Variable | Value (E1) | Bridge use |
|---|---|---|
| `SteamAppId`, `SteamGameId`, `SteamOverlayGameId`, `STEAM_COMPAT_APP_ID` | `620` | Guest: `SteamAppId`/`SteamGameId` for the game |
| `SteamClientLaunch`, `SteamEnv` | `1`, `1` | Guest: tells `steam_api` it was started by Steam |
| `Steam3Master` | `127.0.0.1:<port>`, the running client's local IPC endpoint | **Mac proxy only**: `steamclient.dylib` uses it to reach the client. Never forward it to the guest |
| `SteamUser`, `SteamAppUser` | The account name (9 chars) | **Do not forward** to the guest (privacy; the guest is untrusted) |
| `STEAMVIDEOTOKEN` | A short token (5 chars) | Do not forward |
| A variable with a random 28-character name and an empty value | — | Ignore; do not forward |
| `STEAM_COMPAT_INSTALL_PATH` | `…/steamapps/common/Portal 2` | Mac→guest path mapping root |
| `STEAM_COMPAT_DATA_PATH` | `…/steamapps/compatdata/620` | `getcompatpath`; Cloud mirroring target (Q3) |
| `STEAM_COMPAT_LIBRARY_PATHS` | `…/Steam/steamapps` (one library on this Mac) | Which folders must be shared |
| `STEAM_COMPAT_CLIENT_INSTALL_PATH` | `…/Steam/Steam.AppBundle/Steam/Contents/MacOS`: the folder with `steamclient.dylib`, **not** the Steam root | Mac proxy loads `steamclient.dylib` from here |
| `STEAM_COMPAT_SHADER_PATH` | `…/steamapps/shadercache/620` | Optional: per-game shader cache on the Mac (docs/08) |
| `STEAM_COMPAT_TOOL_PATHS`, `STEAM_EXTRA_COMPAT_TOOLS_PATHS` | The tool's folder; `compatibilitytools.d` | — |
| `STEAM_COMPAT_MOUNTS` | empty | — |
| `STEAM_DYLD_INSERT_LIBRARIES` | `steamloader.dylib:gameoverlayrenderer.dylib` from the client folder | Not used: no overlay in shape B. The proxy must **not** inject them into itself |
| `ENABLE_VK_LAYER_VALVE_steam_overlay_1` | `1` | Not used |
| `STEAM_CLIENT_CONFIG_FILE`, `STEAM_APP_BUNDLE_PATH` | `…/steam.cfg`, `/Applications/Steam.app` | — |
| `PROTON_CRASH_REPORT_DIR` | `/tmp/proton_crashreports` | — |
| `EnableConfiguratorSupport`, `SteamGenericControllers`, `SteamVirtualGamepadInfo`, `SDL_GAMECONTROLLER_*`, `SDL_JOYSTICK_HIDAPI_STEAMXBOX` | Steam Input configuration: device lists, virtual gamepad info file | Later: Steam Input decision (Q4) |

For `steam-run`, that gives:

- Forward **only** an allow-list to the guest: `SteamAppId`, `SteamGameId`,
  `SteamOverlayGameId`, `SteamClientLaunch`, `SteamEnv`, plus the game
  arguments.
- Keep everything else on the Mac, where the proxy inherits it unchanged.
  This is the opposite of FineWine's in-process bridge, which forwards
  every `Steam*` variable, safely, because there everything stays on the
  Mac.

**Stop button (E1 re-run, 2026-11-24 09:55) [seen]:**

- **Steam sends SIGTERM to the script.**
  - Play at 09:55:47; Stop about 6 s later.
  - The script's trap logged `got SIGTERM` at 09:55:53 and exited with 143.
  - `gameprocess_log.txt`: `09:55:54 no longer tracking PID 91708, exit code
    143`, then `Remove 620 from running list`. The session was released in
    the same second.
- So `steam-run` **can** catch Stop and turn it into `terminate` for the
  guest game, then exit once the guest confirms.
- Still unknown:
  - whether Steam escalates to SIGKILL if the script ignores TERM, and
    after how long. E1 exited at once, so it could not show this;
  - whether the TERM also reaches the script's children or process group.
- Because of the first point, `steam-run` should finish its guest terminate
  quickly: close, then kill the guest game within a few seconds. Its Mac
  proxy should still exit by itself when its parent dies, as FineWine's
  watcher does (`SteamPlay.swift:586`).
- FineWine's note that Stop "ends this process, not the Windows game it
  started" (`SteamPlay.swift:620`) agrees with this: the TERM goes to the
  script, and the Wine processes survive it.

### Environment (before E1, from source)

Superseded by the E1 table above; kept for where each name was first found:

| Variable | Meaning | Evidence |
|---|---|---|
| `SteamAppId`, `SteamGameId`, `STEAM_COMPAT_APP_ID` | App id (FineWine takes the first numeric one) | [seen] parser + tests; NotProton's script reads all three |
| `STEAM_COMPAT_INSTALL_PATH` | Game folder (`…/steamapps/common/<dir>`) | [seen] |
| `STEAM_COMPAT_DATA_PATH` | Per-app data, `…/steamapps/compatdata/<appid>`; the folders exist on this Mac | [seen] |
| `STEAM_COMPAT_CLIENT_INSTALL_PATH` | The Mac Steam folder | [seen] |
| `STEAM_COMPAT_LIBRARY_PATHS` | Library roots, space-separated | [seen] NotProton's script iterates it |
| `STEAM_DYLD_INSERT_LIBRARIES` | Steam overlay dylibs to inject (Mac counterpart of `LD_PRELOAD`) | [seen] NotProton; FineWine's bridge uses it |
| `ENABLE_VK_LAYER_VALVE_steam_overlay_1`, other `Steam*`/`STEAM*` | Overlay layer and session info; FineWine forwards every `Steam*`/`STEAM*` variable | [seen] FineWine tests |

- Valve's interface document
  (`steam-runtime-tools/docs/steam-compat-tool-interface.md`) could not be
  fetched: its host refuses automated fetches. E1 (above) dumped the real
  set instead.

### Does the script's lifetime define "playing"? [seen]

**Yes, plus anything else Steam tracks.** `gameprocess_log.txt` for the
same ZZZ launch:

```
17:33:19 AppID 4162040 adding PID 86640 as a tracked process "…/run waitforexitandrun …"
17:33:40 AppID 4162040 adding PID 87131 as a tracked process
17:35:47 AppID 4162040 adding PID 88684 as a tracked process
17:37:20 AppID 4162040 no longer tracking PID 88684 / 87131 / 86640
17:37:20 Remove 4162040 from running list
```

- Steam tracks the script's PID, and also later PIDs. Those later PIDs are
  most likely the Wine processes that called Steamworks through FineWine's
  bridge (`steamclient.dylib` registers its process); that is an inference.
- The game leaves the running list when **all** tracked PIDs have exited.
- For a VM tool, no Mac process except the script talks to Steam (in shape
  A), so **the script's lifetime is exactly "playing"**. The script must
  block until the guest game has exited.
- In shape B, the Mac proxy process loads `steamclient.dylib`, so Steam
  would track it too. That is fine, as long as the proxy exits with the game.
- Steam's **Stop** button ends the script process, not what it started.
  FineWine needed a watcher for this (`startStopWatcher`,
  `SteamPlay.swift:586`). `seemlessctl steam-run` must handle SIGTERM/SIGHUP
  by asking the guest to close the game (then kill it after a timeout), and
  must exit when its parent dies.

## Q2. Files

> Owner decision 1: no Windows Steam in the guest, so the adoption
> question below is moot. The game only has to be **readable at a guest
> path** through a share (S7), and the warnings about not sharing the Mac
> Steam root and about speed still apply.

### Same depot? [seen, strong]

Yes, for the depots a forced tool selects:

- Under a forced tool the Mac client installs the **Windows** depots.
  Portal 2 (which has a native Mac build) was forced to FineWine, and its
  folder holds `portal2.exe`, which the tool was launched with.
- ZZZ (4162040) and Endfield (4732690) are Windows-only. Each has a single
  depot (`4162041`, `4732691`) with a specific `manifest` id in
  `appmanifest_<id>.acf`. A depot manifest id names exact content, so
  Windows Steam on the same branch and build would fetch the same files.
- The `.acf` format is the same on every platform. There is no
  platform-override key in these manifests, so they are not
  Mac-specific.
- [unverified] For apps with OS-filtered or language depots, Windows Steam
  picks the set by its own OS and language. A forced tool should give the
  same set (`from_oslist "windows"`), but Mac Steam may also keep a shared
  depot that Windows Steam would not install. That does not stop adoption.
  At worst Windows Steam fetches a missing depot.

### Can Windows Steam in the VM adopt the folder without re-downloading?

The approach is a known one. People share one NTFS library between Linux
(Proton) and Windows by adding the folder in Windows Steam. Steam reads the
`appmanifest_*.acf` files, checks the files, and shows the games as
installed [reported]. Problems specific to this setup:

1. **Do not share the Mac Steam root.** This Mac has one library, and it is
   the client folder itself (`libraryfolders.vdf`:
   `path = ~/Library/Application Support/Steam`). Sharing it would expose
   `config/`, `userdata/` and the login tokens to the guest, which is
   untrusted (CLAUDE.md, docs/06). Use a **dedicated second library**
   (e.g. `~/Games/Steam VM/`). Mac Steam's "Move install folder" moves a
   game there without re-downloading. Share only that folder.
2. **Windows Steam and shared folders:**
   - Windows Steam lists local fixed drives for libraries and is known to
     reject or mishandle network drives [reported].
   - Whether it accepts the S7 share depends on how the share appears:
     - virtiofs via WinFsp can present a disk-type volume;
     - SMB is a network drive;
     - 9p is unknown.
   - This becomes an **S7 acceptance criterion**: Windows Steam can add the
     share as a library and launch a game from it. (Experiment E3.)
3. **Two writers, one folder.** Both clients would write the same
   `appmanifest_*.acf`, `downloading/` and `temp/`.
   - Rule: **Mac Steam is the only updater.** VM Steam launches only when the
     manifest `buildid` matches the server's.
   - Windows Steam cannot fully turn off updates. "Only update when I launch"
     is the closest setting. So an update can start in the VM. While the
     script is running, Mac Steam does not update that app, so an update in
     the VM is the risk, not a race between the two clients.
   - [unverified] Experiment E3 should watch what Windows Steam writes.
4. **Speed.** docs/08 already says "shared folders are too slow for game
   installs". Loading a game from a share is the same problem: S7 has to
   measure 1 GB sequential and 10k small files, and an asset-heavy load.
   - The fallback is a one-time **import copy** into the VM's Games disk
     (docs/08): a local copy, no download, but twice the disk use, and the
     Mac copy goes stale on updates.
   - Recommendation: share first, import as an option.
5. **Mac-side metadata.** APFS is case-insensitive by default, so it matches
   NTFS. Watch for `._*` AppleDouble files and the `com.apple.quarantine`
   xattr leaking through the share.

## Q3. Two clients, one account

> Owner decision 1: not applicable to the chosen design. There is only one
> Steam client (the Mac one). Kept for the record. The Steam Cloud part
> still applies.

What is documented or reported:

- **Concurrent logins are allowed** [doc]. Steam Remote Play *requires* the
  same account signed in on host and client at once (Steam Support FAQ
  0689-74B8-92AC-10F2). So a Windows Steam client signed in to the same
  account inside the VM is a supported situation in itself.
- **Concurrent playing is not** [reported]:
  - Launching a game while the account is "playing" elsewhere raises a
    prompt. Continuing disconnects the other session from its game.
  - Stale sessions trigger it too: a machine asleep after a game, or one
    that is only downloading.
  - These are community threads quoting the dialog. No Valve page states
    the rule.
- **In shape A:**
  - Mac Steam marks the app as playing the moment the script starts (Q1).
  - When Windows Steam in the VM then launches the same app id, the
    expected result is that prompt in the **guest**, where the user may not
    even see it (seamless mode).
  - Choosing "continue" should take the playing state away from the Mac
    client. What the Mac client then does to the still-running script
    (nothing, a notification, or something else) is **unknown**.

Ways out, in order of preference:

1. **Shape B** removes the problem: there is only one client.
2. **Hand-off** (shape A):
   - The script tells the VM to launch, then exits within a second or two,
     so Mac Steam releases the session before Windows Steam claims it.
   - Cost: Mac Steam stops showing "playing" or counting playtime, and
     its Stop button stops working. Windows Steam in the VM does count
     playtime, on the same account, so nothing is lost server-side.
   - The race between the release on the Mac and the claim in the VM must
     be measured.
3. **Hold** (shape A, if E2 shows it is benign):
   - The script blocks, Windows Steam shows the prompt, and the agent
     dismisses it with "continue".
   - Clicking a dialog in the guest is brittle UI automation. Avoid it.

- **Experiment E2** needs the owner's explicit OK and their account. Sign in
  to Windows Steam in a test VM (Steam Guard treats it as a new device), then
  for one free, non-anti-cheat game:
  - (a) start it from the Mac with a hold-style script, then from VM Steam;
  - (b) the hand-off order.
- Record what each client shows and whether the Mac script is signalled. Do
  not try this with a game that has VAC bans at stake.

### Steam Cloud

- FineWine notes that Mac Steam maps Windows Cloud paths only for a tool
  whose name contains "proton" (`SteamPlay.swift:145`). They are mapped
  into the **prefix** under `STEAM_COMPAT_DATA_PATH`.
- In shape A, saves are written in the VM user's profile, and Windows Steam
  syncs them itself, which is correct.
- The Mac copy of Cloud files in `compatdata` goes stale.
  - Mac Steam only uploads files that changed locally, and nothing changes
    there, so normally nothing is uploaded.
  - [unverified] It could still raise a Cloud conflict prompt on the Mac
    after the VM has uploaded newer saves.
  - The tool should be named without "proton" if that avoids Mac-side Cloud
    for these apps (check in E1/E2).
- In shape B, the saves are written by the game inside the VM, and Mac Steam
  syncs the prefix path. **Auto-Cloud saves would not sync** unless
  `steam-run` mirrors the game's save folders between the guest and
  `compatdata` before and after a run. That is a real design item for
  shape B. ISteamRemoteStorage API saves go over the bridge and are fine.

## Q4. Cross-VM bridge (shape B, chosen)

### Today, in-process (FineWine/Proton) [seen]

- `steam_api64.dll` → `steamclient64.dll`. FineWine's loader patch 0042
  sends this to `lsteamclient.dll` (PE, Windows half).
- The Windows half makes a Wine unix call with a params struct to
  `lsteamclient.so` (Mac half). The Mac half converts the Windows (MSVC)
  struct layouts to Mac (clang) layouts and calls the real interface in
  `steamclient.dylib`.
- Size of Valve's tree in FineWine's build (`build/steam-bridge/lsteamclient`):
  - 92 Steamworks SDK header versions;
  - 213 generated `cppISteam*` files;
  - `unixlib_generated.h` 108.7k lines with **13,100 params structs**
    (64-bit and WOW64, every interface version);
  - `unixlib_generated.cpp` 28.8k lines;
  - `steamclient_structs_generated.h` 11.5k lines;
  - `gen_wrapper.py` 1.8k lines;
  - ~3.2k lines of hand-written `*_manual.*` (input, matchmaking,
    networking, remote storage, utils) and `unixlib.cpp` 1.7k lines.
- Callbacks are already pumped, not called across. The Mac half queues them
  (`queue_vtable_callback`, `unixlib.cpp:52`) and the Windows half drains
  the queue.

### Proposed design

- **Guest half:** a Windows `steamclient64.dll` stand-in (x64, because games
  run under Prism; ARM64EC is not needed).
  - Real Windows finds Steam's client library through the registry
    (`HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64`), so
    **no loader patch** is needed. A guest helper (like FineWine's
    `steam.exe`) sets the key and starts the game.
  - Each interface method serialises its arguments and sends them over a
    local named pipe to the Seemless session agent. The agent forwards
    them as **opaque frames** over virtio-serial.
- **Host half:** a Mac process started by `seemlessctl steam-run` (in
  FineWine's code; see Ownership).
  - It loads `steamclient.dylib`, connects as the app id, and so is the
    tracked "game" process (Q1).
  - It deserialises each call, validates it, calls Steam, and replies.
  - Callbacks and call results are queued and returned in poll replies.

### What breaks

| Problem | Why | Fix |
|---|---|---|
| Pointers into game memory | In-process, params carry raw pointers (`char *buf, int cbBuf`, out structs, arrays). Across a VM nothing can be dereferenced | Copy in and out with explicit lengths. Recent SDKs ship `steam_api.json` with `out_string_count` / `array_count` / `out_buffer_count`-style annotations [unverified exact names]. Older interface versions (~half of the 92) need hand annotations |
| Struct layout | Already solved for Win↔Mac by the generator | Serialise fields, not memory images |
| Interface pointers / vtables | `GetISteamX()` returns objects | Handle ids; the guest half owns vtables that call by id |
| Callback *objects* | `ISteamMatchmakingServerListResponse`, `…PingResponse`, `…PlayersResponse`, `…RulesResponse`: Steam calls methods on game objects. Also function hooks (`SetWarningMessageHook`, `SetDebugOutputFunction`) | Host stub objects queue events; the guest half calls the game's objects on its own thread. This is the existing `queue_vtable_callback` model, plus a transport |
| Memory ownership | `SteamNetworkingMessage_t` carries `pData` and a `Release` function pointer; `AllocateMessage` | Guest half allocates and owns the guest-side copies, and releases the host-side message after copying |
| Paths | `GetAppInstallDir`, `GetFileDetails`, etc. return Mac paths | Map share paths ↔ guest drive paths; anything outside the share is refused. lsteamclient already converts Unix→NT paths (`unixlib.cpp:692`); this needs share-aware mapping instead |
| Per-call latency | Games call `SteamAPI_RunCallbacks` every frame, and some call Steam Input / `ISteamUtils` many times per frame | Batch the per-frame calls; cache pure getters; **measure the virtio-serial round trip first** (it does not exist yet: WP4.2) |
| Overlay | The Mac overlay injects into a Mac process via `STEAM_DYLD_INSERT_LIBRARIES`; the game's frames are in the guest | No Steam overlay in shape B. Overlay-dependent features break: microtransaction approval dialogs and invite UI. Shape A has the real Windows overlay |
| Steam Input | Mac Steam owns the controllers; the guest sees XInput (docs/07) | Use Steam Input's action API over the bridge, or turn it off for these games. Needs a decision |
| VAC | Needs Windows Steam's service | Not available, the same as on Proton |
| Untrusted guest | The guest can call any Steamworks method as the user for that app id (friends chat, workshop upload, inventory) | Allow-list interfaces and methods, cap every length, rate-limit, log. The Mac proxy is the trust boundary, not the guest DLL |

### Size

These are estimates for one experienced person, assuming the Seemless
transport exists:

- **Proof of concept, about 4 weeks:**
  - latest SDK only;
  - `ISteamClient`/`User`/`Apps`/`UserStats`/`Utils`/`Friends` (read);
  - ownership, auth tickets, achievements, rich presence;
  - callbacks and call results;
  - a generator back end that emits serialisers from `steam_api.json`.
- **Matching FineWine's bridge, 3–6 months:**
  - every interface version the 92 SDKs cover (mostly generated, with
    many hand annotations for pre-JSON SDKs);
  - the four response-object interfaces;
  - networking sockets and messages;
  - remote storage, UGC, HTML surface, input;
  - Cloud folder mirroring;
  - WOW64 is not needed, because the guest is real Windows.
- **Ongoing:** each new SDK version adds interfaces to annotate, the same
  upkeep Proton has.

## Q5. Anti-cheat (background only: owner decision 3)

The pseudo-prefix is built regardless of these results. They only feed the
per-game picker and the "known-blocked" message. The key constraint first:

- **Windows on ARM runs x64 apps under Prism, but not x64 kernel drivers.**
- A kernel anti-cheat works in the guest only if the vendor ships an ARM64
  driver **and** the game does not refuse VMs.
- Seemless does not hide the hypervisor (docs/00, R15), and will not.
  - QEMU's SMBIOS strings, ACPI tables and virtio devices are all visible.
  - ARM has no CPUID hypervisor bit, but those signals are enough.

| Anti-cheat | ARM64 Windows | VM policy | Shape A VM? |
|---|---|---|---|
| **Easy Anti-Cheat** | Yes since Aug 2025, per game: the game must ship EOS SDK 1.19.1+ [doc, Epic news] | Developer choice per title. Fortnite and others refuse VMs ("cannot run under a virtual machine") [reported] | Only titles that ship ARM64 EAC **and** allow VMs: a small set, which must be checked per title |
| **BattlEye** | Supported from Windows 11 24H2 build 26100.863 [doc, Microsoft DirectX blog]. Our build 26300 qualifies | FAQ says nothing about VMs [doc]. Users report VM blocks [reported] | Per title, the same as EAC |
| **Riot Vanguard** | No ARM64 driver known | **Refuses VMs**: VAN 9100 "Unsupported virtualized environment" [doc, Riot support] | **Never** |
| **Tencent ACE** | Nothing found for Windows ARM64 | Markets detection of "30+ kinds of virtual machines" [doc, Tencent Cloud] | Assume never |
| **VAC** | User-mode inside Windows Steam (x64, runs under Prism) | No VM policy known | Works in shape A [unverified]; **not** in shape B or the Wine tool |

What that means for picking a tool, per game:

- **Wine tool (FineWine), default:**
  - anything that works there;
  - lower RAM and start-up cost;
  - no second Steam client;
  - games whose anti-cheat only runs in user mode, or is disabled under
    Wine.
  - Note: EAC's and BattlEye's Proton support loads a **Linux** library, so
    it is not expected to work under Wine on macOS [unverified for
    FineWine].
- **VM tool (Seemless):**
  - games Wine cannot run for non-anti-cheat reasons: launchers, DRM,
    .NET/UWP-heavy titles, D3D12 once WP7.5 lands, and missing Win32 APIs;
  - VAC multiplayer under shape A;
  - EAC and BattlEye titles confirmed to ship ARM64 and allow VMs.
- **Neither:** Vanguard, ACE, and EAC/BattlEye titles without ARM64 drivers
  or with VM blocks.
- **Detection hint for FineWine's picker:** scan the install folder for
  `EasyAntiCheat/`, `BattlEye/`, `vgk.sys`, `ACE-*` before offering the VM
  tool, and say why it is not offered. The same strings drive R15's
  "known-blocked title" message in Seemless.

## Q6. What Seemless needs first, and a plan

### Prerequisites in Seemless

For the proof of concept:

| Item | Why | Status |
|---|---|---|
| **Third `virtserialport` `seemless.steam`** (opt-in per VM) | Bridge transport and launch/exit messages for the PoC | New; one `-device` line (Transport) |
| **`seemlessctl steam-run --vm <name> -- <verb> <exe> [args]`** | What FineWine's script execs; starts the Mac proxy, maps paths, forwards Stop | New; uses `VMManager` start/resume (exists) |
| **Game files visible in the guest** | The game runs from a guest path | PoC: copy or manual SMB. Product: S7 shares + Mac→guest path mapping (spike not run) |
| **Dependency runner** (installscript `Run Process` + `HasRunKey`, `_CommonRedist`) | Windows Steam is not there to do it | New (Game dependencies). PoC: FineWine's guest helper can run it; product: Seemless guest side |
| **Network on for game VMs** | Games' own servers | Exists (`.user` default). Later: "Game network" setting, inbound forwards |
| **Round-trip benchmark** (`seemlessctl bench`) | Bridge latency decides batching | New (E5) |

After the proof of concept:

| Item | Why | Status |
|---|---|---|
| **WP4.2 agent** + opaque `stream.v1` channel (named pipe → agent → host socket) | Many games and streams, validated like every agent message | Not started; protocol and mock done (WP4.1) |
| **Launch with a handle**: `Launch` replies with a `launch_id`; `ProcessExited { launch_id, exit_code }`; `Terminate { launch_id, grace_ms }` | Replaces the helper's own launch messages | Not in `proto/seemless.proto` (Launch has no reply data today) |
| **Dependency catalogue** (runtime-fetched, hash-pinned, never bundled) | Runtimes Steam does not list (.NET, XNA, PhysX...) | New |
| **Sealed golden image + per-game VMs** (app-id tag in `VMConfig`) | The per-game pseudo-prefix | Overlay model designed (docs/02); sealing not started |
| **Warm VM policy**: pause or hibernate after the game, idle timeout | Second launch near-instant, like a prefix | Needs S6 hibernate validated |
| **Game mode** (docs/08) | Fullscreen, relative mouse, frame pacing | Not started |

### Proof-of-concept plan (shape B)

- **PoC target:** one small, 64-bit Steamworks game the owner owns, run from
  Mac Steam with the new tool.
  - Pick a game with **achievements** and an **ownership check**, no
    anti-cheat, and D3D11.
  - Spacewar (app 480, Valve's Steamworks sample) is the classic test app,
    but it needs the SDK's example sources built for Windows. A real small
    game is less work.
- **PoC acceptance:**
  1. Steam's Play button starts the game in the VM.
  2. Mac Steam shows it as playing for the whole session.
  3. `SteamAPI_Init` succeeds.
  4. `BIsSubscribedApp` / `GetSteamID` return the real values.
  5. An achievement unlocks on the account.
  6. Quitting the game removes "playing" within a few seconds.
  7. Steam's Stop button closes the game in the VM.
  - Evidence: Mac Steam's `gameprocess_log.txt` lines, bridge logs, and a
    `seemlessctl screenshot`.

**Step 0. Experiments** (owner's OK each; no product code):

- E1: environment and argv dump (Q1). Done 2026-11-24, including Stop.
- E5: virtio-serial round trip (Transport).
- E6: on build 26300 ARM64, `_CommonRedist` VC++ 2022 x64 and DirectX
  Jun2010 install, and a D3D11 x64 game starts after them.

**Step 1. Seemless, minimum** (no WP4.2 needed):

- a third `virtserialport` named `seemless.steam` with a unix-socket
  chardev, opt-in per VM (`vm set --steam-port on`), with a snapshot test
  of the QEMU arguments;
- the game folder visible in the guest:
  - simplest for the PoC: copy the game into the VM, or use macOS File
    Sharing (SMB) by hand;
  - S7 replaces this;
- `seemlessctl steam-run --vm <vm> -- <verb> <exe> [args]`:
  - answers `getcompatpath`;
  - starts or resumes the VM;
  - maps the Mac path to the guest path;
  - starts FineWine's Mac proxy with the port's socket path and the Steam
    environment;
  - forwards SIGTERM/SIGHUP to the proxy;
  - exits with the game.

**Step 2. FineWine, the bridge** (its code; Steamworks licence):

- **Guest helper (Windows, x64):**
  - logon task or service;
  - listens on `\\.\Global\seemless.steam`;
  - on `launch {exe, args, cwd, appid}`: sets the `SteamClientDll64` key
    to the stand-in, sets `SteamAppId`/`SteamGameId`, starts the game, and
    waits for its process tree;
  - sends `exited {code}` when the tree is gone;
  - on `terminate`: closes the main window, then kills after a timeout.
  - The same channel then carries the Steamworks RPC: the helper proxies
    named-pipe connections from the stand-in DLL in each game process.
- **Stand-in `steamclient64.dll` (x64):** `lsteamclient`'s Windows half,
  with the unix-call layer replaced by "serialise, send over the pipe, wait
  for the reply".
  - PoC interfaces: `ISteamClient`, `ISteamUser`, `ISteamApps`,
    `ISteamUserStats`, `ISteamUtils`, `ISteamFriends` (read and rich
    presence), plus callbacks and call results.
  - Latest SDK version only.
- **Mac proxy:** `lsteamclient`'s Mac half as a standalone arm64 process.
  - It loads `steamclient.dylib`, connects for the app id, deserialises and
    validates every call (interface allow-list, length caps), and calls
    through.
  - It queues callbacks for the guest's poll replies.
- **Generator back end:** emits the serialisers, from `steam_api.json`
  annotations where they exist and hand annotations for the PoC methods.
- **The tool:** a `seemless-vm` folder in `compatibilitytools.d` whose
  `run` execs `seemlessctl steam-run`, beside `finewine-proton`.

**Step 3. Dependencies, minimum:**

- `steam-run` passes the game's `installscript.vdf` and the `_CommonRedist`
  folder;
- the guest helper runs the `Run Process` entries once per `HasRunKey`
  before launch;
- the catalogue fallback is not needed for the PoC.

**After the PoC:**

- move the channel onto the WP4.2 agent (`stream.v1`, several games at
  once) and launches onto `Launch` + `ProcessExited`;
- S7 shares and path mapping;
- the dependency catalogue;
- the "Game network" setting;
- per-game overlays;
- game mode;
- Cloud save mirroring;
- the rest of the interfaces, toward parity.

### Ownership

| Part | Repository | Why |
|---|---|---|
| Compat tool folder (`compatibilitytool.vdf`, `toolmanifest.vdf`, `run`), per-game picker, anti-cheat scan, library-move help | **FineWine** | It already installs and manages Steam tools beside NotProton/Bridgeplay, which Mac Steam needs before it offers any tool |
| `seemlessctl steam-run`, the `seemless.steam` port (later `stream.v1` over the agent), Launch handle / `ProcessExited` / `Terminate`, S7 shares + path mapping, dependency runner + catalogue (product), network settings, game mode, round-trip bench | **Seemless** | Generic VM features; nothing Valve-licensed |
| Guest Steam helper (listens on the port, sets `SteamClientDll64`, starts and watches the game, runs install scripts in the PoC) | **FineWine** (built for Windows) | Derived from Valve's BSD `steam.cpp` helper |
| Cross-VM `lsteamclient` (guest DLL + Mac proxy + generator back end) | **FineWine**, or a separate repository with the Steamworks SDK licence | `lsteamclient` and the SDK headers are under the **Steamworks SDK licence** (`runtime-extras/steam-bridge/README.md`). Keep it out of Seemless. Seemless only carries opaque bytes |

Seemless delivers FineWine's guest binaries the same way it delivers any
user app: through `Launch` from a share, or `vm open`. It never bundles them.

## Dependencies and risks (new)

- Mac Steam offers compat tools only after NotProton or Bridgeplay has
  patched the client (`SteamPlay.swift:6`). A Valve client update can break
  this whole feature, as it can FineWine's.
- **Per-call latency** across the VM boundary is unmeasured (E5). It is the
  main technical risk of the bridge.
- **Steamworks surface the guest can reach:** a compromised guest can call
  whatever the proxy allows, as the user, for that app id. The proxy's
  allow-list is the trust boundary.
- **No overlay, no VAC** in this design. Overlay-dependent flows
  (microtransaction approval, some invite UIs) fail.
- **Cloud auto-saves** live in the guest profile, while Mac Steam syncs the
  prefix path. Without mirroring, saves do not sync (Q3).
- **RAM:** a VM running a game alongside Mac Steam. docs/02 defaults to
  8 GiB; games may want more.
- **Dependencies on ARM64:** x64 redistributables under Prism are mostly
  fine. Kernel-driver installers fail (E6).

## Experiments needing the owner (none were run)

| Id | What | Touches |
|---|---|---|
| E1 | Env/argv dump tool for one game | **Done 2026-11-24** (Portal 2), including Stop (SIGTERM); results in Q1 |
| E5 | Virtio-serial round trip over a third port | Test VM only; a throwaway `-device` line |
| E6 | `_CommonRedist` VC++ x64 + DirectX Jun2010 on 26300 ARM64, then a D3D11 x64 game | Test VM; copies redists from the Mac library |
| ~~E2~~ | Two clients, one account | Dropped: no Windows Steam in the guest (owner decision 1) |
| ~~E3~~, ~~E4~~ | Windows Steam adopting the share; Windows Steam on ARM64 | Dropped for the same reason |

## Sources

Local (read only, 2026-11-24):

- `~/Library/Application Support/Steam/logs/compat_log.txt` and
  `gameprocess_log.txt`;
- the `steamapps/appmanifest_{620,4162040,4732690}.acf` files and
  `steamapps/libraryfolders.vdf`;
- `compatibilitytools.d/notproton-26.3/run`;
- FineWine `SteamPlay.swift`, `runtime-extras/steam-bridge/README.md`, and
  `build/steam-bridge/lsteamclient/`.

Web:

- [Steam compat tool interface (Valve, steam-runtime-tools)](https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/0cc0c2cea1234ece877629343a0955fd2606fbb8/docs/steam-compat-tool-interface.md).
  Only the search summary was available: manifest v2, `%verb%`,
  `waitforexitandrun`. The page itself refused automated fetches.
- [Steam Support: Remote Play, same account on both computers](https://help.steampowered.com/faqs/view/0689-74B8-92AC-10F2)
- Playing on another computer [reported]:
  - [Steam forum thread](https://steamcommunity.com/discussions/forum/1/2953754543762809314)
  - [Factorio forum: "Game already running"](https://forums.factorio.com/viewtopic.php?p=133517)
- [Riot: VAN 9100, unsupported virtualized environment](https://support.riotgames.com/en-us/riot/client/error-van-9100),
  [VAN 138](https://support.riotgames.com/en-us/riot/performance/error-van-138)
- [Epic: Online Services and Fortnite on Windows on Snapdragon](https://onlineservices.epicgames.com/news/online-services-and-fortnite-are-now-available-on-windows-on-snapdragon),
  [Tom's Hardware: EAC for ARM](https://www.tomshardware.com/video-games/pc-gaming/epic-games-adds-easy-anti-cheat-for-arm-devices-feature-unlocks-support-for-windows-linux-and-switch-2)
- [Microsoft DirectX blog: gaming on Arm 2024 (BattlEye 26100.863)](https://devblogs.microsoft.com/directx/step-forward-for-gaming-on-arm-devices-2024)
- [BattlEye FAQ](https://www.battleye.com/support/faq/) (no VM statement)
- [Unraid forum: EAC "cannot run under virtual machine"](https://forums.unraid.net/topic/127639-easy-anti-cheat-launch-error-cannot-run-under-virtual-machine/page/2/),
  [Unraid forum: blocked by BattlEye](https://forums.unraid.net/topic/133384-blocked-by-battleye-for-virtual-machine)
- [Tencent Cloud: ACE](https://intl.cloud.tencent.com/document/product/1018/30303)
