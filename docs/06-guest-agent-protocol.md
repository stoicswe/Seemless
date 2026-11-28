# 06 — Guest agent and host↔guest protocol

## Agent processes

| Binary | Runs as | Started by | Responsibilities |
|--------|---------|------------|------------------|
| `seemless-agent-svc.exe` | LocalSystem Windows service, auto-start | SCM | Owns the virtio-serial ports; launches and supervises the session agent in the interactive session (`WTSQueryUserToken` + `CreateProcessAsUser`); self-update; power, time sync, shutdown; driver updates; survives logoff |
| `seemless-agent.exe` | The logged-on user, interactive desktop, UIAccess | Service | Window tracking, capture/atlas, input assist, clipboard, drag and drop, app catalogue, notifications, file open, DPI/display settings |

The service is the single owner of the serial ports and multiplexes for the
session agent over a local named pipe. This keeps the link alive across
logoff, session agent crashes and updates. The pipe is
`\\.\pipe\seemless-agent-<32 random hex>`: a new name each time the service
starts, created with `FILE_FLAG_FIRST_PIPE_INSTANCE` and passed to the session
agent on its command line, so no other process can create it first and pose
as the service. Its DACL admits SYSTEM and interactive users, it rejects
remote clients, and the service accepts only the process id of the session
agent it started.

Rust workspace layout (`guest/agent/`):

```
crates/
  proto/        # prost-generated types from /proto, framing, version negotiation
  transport/    # vioserial port discovery + overlapped I/O; named pipe
  svc/          # service binary
  session/      # session agent binary
  windows-model/# window enumeration, classification, rules.toml (pure logic, unit-testable with recorded dumps)
  capture/      # WGC + D3D11 atlas
  shell/        # app catalogue, icons, jump lists, file associations, notifications
  clip/         # clipboard + drag and drop
  protogen/     # host dev tool: runs protoc-gen-swift via protox (scripts/gen-proto.sh)
```

Build from macOS with `guest/tools/build-agent.sh`, or by hand from inside
`guest/agent` (rustup picks the pinned toolchain, which has the Windows
target, from the current directory, not from `--manifest-path`):
`cd guest/agent && ~/.cargo/bin/cargo xwin build --target
aarch64-pc-windows-msvc --release`. Unit tests for pure-logic crates run on the Mac host
(`cargo test -p windows-model`); Windows-API crates are tested in the VM via
`seemlessctl guest test` (copies a test binary through the bulk channel and
runs it).

## Transport and framing

- Two virtio-serial ports (02). The guest opens them by port name: the
  vioserial driver publishes each named port as `\\.\Global\<name>` (the
  same path qemu-guest-agent uses), so no SetupAPI enumeration is needed
  (WP4.2). Handles are overlapped, so a pending read never blocks a write.
- Frame: `u32 length (LE) | u8 kind | payload`, where `length` is the payload
  length (the kind byte is not counted). `kind` 0 = Protobuf `Envelope`,
  1 = raw bulk chunk (bulk port only). Max payload 1 MiB on control, 4 MiB on
  bulk; the length is checked as soon as the 5-byte header arrives. A
  receiver that sees an oversized or malformed frame, an unknown kind or an
  undecodable `Envelope` resets the channel (close, reopen, renegotiate).
  Frames that arrived complete before the bad one are still delivered.
- `Envelope { uint64 seq; uint64 reply_to; oneof body {...} }`. `seq` starts
  at 1 per connection and increases. Responses set `reply_to` to the
  request's `seq`; events and requests have `reply_to = 0`. A reply to an
  unknown or timed-out `seq` is dropped. A body this build does not know
  (newer minor) decodes as empty and is ignored.
- **Requests and replies**: every H→G message other than `Hello`/`Ping` is a
  request and gets exactly one reply: its data reply (`GuestInfo`,
  `HitTestResult`, `AppList`, `BulkOffer`, `RunCommandResult`, `Activated`),
  `Ack`, or `Error { code, message }` (`UNSUPPORTED` for anything the agent
  cannot do). G→H messages are events, except `OpenOnHost` and
  `ClipboardRequest`, which the host answers the same way.
- **Handshake**: both sides send `Hello { protocol_major, protocol_minor,
  build, capabilities[], role }` on connect with `reply_to = 0`, and answer
  every `Hello` that has `reply_to = 0` with their own (`reply_to` = its seq).
  virtio-serial drops bytes written while the other end has the port closed,
  so this guarantees each side sees the other's Hello whoever starts first.
  Major mismatch → host offers to update guest tools; minor only informs.
  Features are gated on capability strings (`core.v1`, `system.v1`,
  `windows.v1`, `apps.v1`, `clipboard.v1`, `dragdrop.v1`), used only when
  both sides list them. Hello limits (the guest is untrusted): build ≤ 256
  bytes, ≤ 64 capabilities, each 1–64 bytes of `[a-z0-9._-]`; the role must
  be the opposite of ours.
- **Heartbeat**: `Ping`/`Pong` every 1 s; 3 missed → "agent lost" (05).
  The host reports `unresponsive` and `responsive` again when Pongs return;
  the connection stays open.
- virtio-serial gives no connect/disconnect framing guarantee beyond
  open/close events, so after any reconnect the agent sends a full
  `WindowSnapshot` and the host discards prior state. A `Hello` with
  `reply_to = 0` after the session is up means the agent restarted: pending
  requests fail and the host treats it the same way.

Implementation (WP4.1): schema `proto/seemless.proto`; Rust types generated
at build time (`crates/proto/build.rs`, protox + prost, no `protoc`), Swift
types checked in at `kit/Sources/SeemlessKit/Agent/Generated/` and
regenerated by `scripts/gen-proto.sh` (`--check` runs in `check.sh`).
Framing and handshake exist twice (`crates/proto/src/{frame,handshake}.rs`,
`SeemlessKit/Agent/Agent{Frame,Handshake}.swift`). The golden frames in
`proto/testdata/` keep the two byte-identical, and both test suites check
them. Regenerate them with `SEEMLESS_BLESS=1 cargo test -p proto` after a
deliberate change.

## Agent implementation (WP4.2)

Crates: `transport` (`link`: framed reader/writer threads over any byte
stream, with a bounded write queue that drops when full; `win`: vioserial
port and pipe), `svc` (`router`: sans-IO routing; `serve`: event loop; `win`:
SCM, supervisor, GuestInfo), `session` (`Core`: sans-IO; `main`: pipe
client). `router`, `serve`, `link` and `session::Core` are tested on the Mac
over unix sockets; only the `win` modules are Windows-only.

- **Service** (`seemless-agent-svc.exe`, service `SeemlessAgent`, LocalSystem,
  auto-start, restarted by the SCM on failure). `console [--supervise]` runs
  the same loop in a console; `info` prints GuestInfo. Log:
  `%ProgramData%\Seemless\logs\agent-svc.log` (one `.1` kept past 1 MiB).
- **Host link.** The service opens the control port, sends `Hello`, and
  reopens the port 1 s after it fails (missing driver, read error). It answers
  `Hello`, `Ping`, `GetGuestInfo`, `UpdateTools` (WP4.3), `TimeSync`,
  `Shutdown` and `SetHostInfo` (WP4.4, "Session and system" below)
  itself and advertises `core.v1` + `system.v1`; `RunCommand` gets `Error
  UNSUPPORTED`; window, app, clipboard and drag requests
  are forwarded to the session agent (`UNSUPPORTED` when none is running).
  A host `Hello` with `reply_to = 0` starts a new host connection: seqs
  restart at 1 and requests in flight across the service are dropped.
  After a framing error the decoder restarts with the next read; bytes that
  arrived in the same read as the bad frame are discarded.
- **GuestInfo** (registry): `os_build` = product name (corrected to
  "Windows 11" from build 22000), display version and `10.0.<build>.<UBR>`;
  `gpu_adapter` = Display-class `DriverDesc`s; `driver_versions` = Display
  devices plus VirtIO/Red Hat drivers in the System, Net and SCSI classes.
  Strings capped at 128 characters, at most 32 drivers.
- **Session pipe.** Same framing and `Envelope`s. The session agent sends
  `Hello` (role `GUEST_SERVICE`); the service answers with role `HOST`
  (service and session agent ship together, so their versions must match
  exactly), then forwards the host's current `Hello` and every later one
  (a host (re)connect: the session agent resends its state). Pipe seqs are
  separate; the service maps request and reply seqs between the links. The
  session agent may send only window/app/clipboard/drag events, `OpenOnHost`
  and `ClipboardRequest` (requests), and replies to forwarded requests;
  anything else is dropped. It may claim only `windows.v1`, `apps.v1`,
  `clipboard.v1` and `dragdrop.v1`.
- **Capabilities.** The service advertises `core.v1` plus the session
  agent's capabilities. When that set changes (agent connects or exits) it
  sends the host a fresh `Hello`, which the host treats as an agent restart.
- **Supervision.** Every 2 s, if no session agent runs and a user is logged
  on at the console, the service starts `seemless-agent.exe --pipe <path>`
  as that user on `winsta0\default` (`WTSQueryUserToken` +
  `CreateProcessAsUser`). An exit is restarted with a backoff of 1 s doubling
  to 30 s, reset after a minute of running. The session agent exits when the
  pipe closes. Not yet: UIAccess (needs a signed binary), session-change
  notifications (polling covers them).
- **Session agent** (`seemless-agent.exe`, GUI subsystem, no window): the
  WP4.2 skeleton claims no capabilities and answers every forwarded request
  `Error UNSUPPORTED`. Log: `%LOCALAPPDATA%\Seemless\logs\agent.log`.
- **Install.** `guest/tools/build-agent.sh` builds both binaries
  (cargo-xwin) and stages `build/guest-tools/agent/` (binaries,
  `install.cmd`, `uninstall.cmd`, `version.txt`). The C runtime is linked
  statically (`guest/agent/.cargo/config.toml`, `+crt-static`): a clean
  Windows has no `VCRUNTIME140.dll`, and the first dynamically linked build
  never started there. The exes import only system DLLs; check with
  `llvm-objdump -p <exe> | grep "DLL Name"`. Redistribution: docs/10 Q12. `seemlessctl image build
  --agent build/guest-tools/agent` copies it to `%ProgramFiles%\Seemless`
  (apply.cmd) and `firstboot.cmd` runs `install.cmd` (`sc create`, failure
  restarts, `sc start`). The vioserial driver comes from `--drivers`. In-place
  updates: "Guest tools ISO" below.

- **Writes to the host port** (WP4.4 finding). After a host disconnects,
  a write the service sends unprompted (a `SessionState` change) could
  stay queued in the virtio-serial path forever on this QEMU + vioserial
  build, blocking every later write, including the Hello reply to the next
  host (the agent looked dead for minutes). The serial writer therefore asks
  the driver first (`IOCTL_GET_INFORMATION` → `VIRTIO_PORT_INFO.HostConnected`)
  and drops the frame while no host is connected; treats `STATUS_CANT_WAIT`
  (554) the same; and cancels and drops a write that makes no progress for
  5 s. Dropped frames are logged (1st, 2nd, 4th, …). A reconnecting host
  always starts with Hello, so nothing it needs is lost.

## Message catalogue (v1)

Direction: H→G host to guest, G→H guest to host. This table is the contract;
`proto/seemless.proto` implements it.

### Session and system

| Message | Dir | Purpose |
|---------|-----|---------|
| `Hello`, `Ping`, `Pong` | both | Handshake, liveness |
| `SessionState { logged_on, locked, user, secure_desktop }` | G→H | Host shows desktop mode when locked or on secure desktop |
| `SetHostInfo { displays[], scale, work_area, locale, keyboard_layout, timezone, appearance(dark/light) }` | H→G | Agent applies resolution/DPI/work area/theme |
| `TimeSync { unix_nanos }` | H→G | After start and resume |
| `Shutdown { mode: shutdown|restart|logoff|hibernate }` | H→G | Graceful power |
| `GuestInfo { os_build, driver_versions, agent_version, gpu_adapter }` | G→H | Diagnostics |
| `UpdateTools { iso_volume_label, version }` | H→G | Service installs from attached tools ISO |

**Built (WP4.4, capability `system.v1`, all in the service):**

- `SessionState`: the service polls the console session every 2 s
  (`WTSGetActiveConsoleSessionId` + `WTSQuerySessionInformationW
  (WTSSessionInfoEx)`: user name, lock flag) and sends it right after each
  host Hello and on every change. `secure_desktop` is not detected yet
  (always false). `logged_on` is true for any user, including OOBE's
  temporary `defaultuser0`; the host decides what counts as a desktop.
- `TimeSync`: range-checked (2020–2200), then `SetSystemTime` with
  SeSystemtimePrivilege. `Ack`, or `Error INTERNAL` if Windows refused.
- `Shutdown`: shutdown/restart via `InitiateSystemShutdownExW` (apps asked,
  not forced; planned reason), logoff via `WTSLogoffSession` on the console
  session; started 1 s after the `Ack`. `HIBERNATE` → `UNSUPPORTED` (S6b).
- `SetHostInfo`: bounds-checked, `Ack`ed and stored by the service, sent to
  the session agent (and replayed to each new one). The session agent
  applies only `appearance` so far: `AppsUseLightTheme` +
  `SystemUsesLightTheme` under `HKCU\…\Themes\Personalize`, then a
  `WM_SETTINGCHANGE "ImmersiveColorSet"` broadcast. Resolution follows the
  display path (docs/04); DPI, work area, locale, keyboard layout and time
  zone are not applied yet.

**Host side: `AgentLink`** (`kit/Sources/SeemlessKit/Agent/AgentLink.swift`),
run by whoever owns the VM process (`VMManager.start` for the app, `vm run`
for the CLI) unless quarantine has the agent connection off. QEMU's agent
chardev serves one client at a time, so the link never holds it: each sync
is a short connection (Hello → the service's `SessionState` → `TimeSync` →
`SetHostInfo` → close). It syncs at start, every 5 min (every 5 s while an
offline first setup is pending), when the Mac's appearance changes
(`AppleInterfaceStyle`, checked every 2 s) and after resume. When a sync
sees a signed-in desktop (`logged_on`, not locked, not secure desktop, user
not `defaultuser*`), it calls `VMManager.finishOfflineSetup` once (docs/02
"Network link"). No agent, an old agent without `system.v1`, or no agent
channel at all is normal: syncs fail quietly. `seemlessctl agent sync`
runs one sync by hand; `SEEMLESS_AGENT_LINK_SKIP=time,hostinfo|all`
(debugging) leaves parts out in `vm run`.

**Graceful stop:** `VMManager.stop`, `seemlessctl vm stop` and Ctrl-C in
`vm run` first send `Shutdown` through the agent, then fall back to the
ACPI power button and finally a forced stop. `seemlessctl agent shutdown
--mode shutdown|restart|logoff` sends it alone.

### Windows (seamless)

| Message | Dir | Purpose |
|---------|-----|---------|
| `WindowSnapshot { windows[] }` | G→H | Full state after connect |
| `WindowAdded/Updated { id, owner_id, class(kind), rect, title, app_key, pid, state(min/max/normal), flags(resizable, topmost, has_alpha), icon_id }` | G→H | Incremental; `Updated` is field-masked and coalesced to at most one per window per frame |
| `WindowRemoved { id }` | G→H | |
| `AtlasFrame { serial, entries[{ id, atlas_rect, content_size }] }` | G→H | Which windows changed in atlas present `serial` |
| `ForegroundChanged { id }` | G→H | Guest-initiated focus change → host orders that `NSWindow` front (subject to focus-stealing policy) |
| `PointerFocus { id }` | H→G | Raise without activate |
| `Activate { id }` / `Activated { id }` | H→G / G→H | Key focus handshake |
| `Deactivate {}` | H→G | Mac app took focus |
| `SetWindowRect { id, rect, flags }` | H→G | Host-driven move, zoom, tiling |
| `WindowCommand { id, cmd: close|minimize|restore|maximize }` | H→G | Title-bar-equivalent actions from Mac menus/Dock |
| `HitTest { id, point } → HitTestResult { code }` | H→G | For host-driven move (v2) |
| `CursorState { visible, clipped, clip_rect }` | G→H | Game-mode detection (08) |
| `FullscreenState { id, exclusive }` | G→H | Game-mode trigger |

Window ids are agent-assigned `u64`s, not raw HWNDs (HWNDs get reused).

### Apps and shell

| Message | Dir | Purpose |
|---------|-----|---------|
| `ListApps → AppList { apps[{ app_key, name, exe, args, icon_id, source: start_menu|uwp|running }] }` | H→G | Start-menu catalogue for the launcher |
| `AppsChanged` | G→H | Start menu folders changed (install/uninstall) |
| `GetIcon { icon_id, size } → bulk transfer (PNG)` | H→G | Icons at 32/64/256/512 |
| `Launch { app_key | path, args, files[], verb }` | H→G | Start an app or open a document |
| `OpenOnHost { kind: url|path, value }` | G→H | Guest asks host to open a link/file with a Mac app (policy-checked) |
| `Notification { app_key, title, body, icon_id, tag }` | G→H | Toast forwarding |
| `TrayItems { items[] }`, `TrayInvoke { id, action }` | G→H / H→G | Notification-area icons surfaced in the Mac menu bar extra (M6) |
| `RunCommand { exe, args, elevated, capture_output }` | H→G | Diagnostics and scripted setup only; never exposed to untrusted input |

### Clipboard and drag and drop

| Message | Dir | Purpose |
|---------|-----|---------|
| `ClipboardOffer { serial, formats[] }` | both | Lazy: announce formats on change, do not send data |
| `ClipboardRequest { serial, format } → bulk transfer` | both | Fetch on paste (delayed rendering on Windows, promised data on macOS) |
| `DragEnter/Move/Leave/Drop { window_id, point, formats[] }` | H→G | Mac → Windows drag; agent runs an OLE drag source proxy |
| `DragStart { formats[], preview_icon }` … | G→H | Windows → Mac drag (M6, harder) |

Formats in v1: plain text (UTF-8 ↔ `CF_UNICODETEXT`), RTF, HTML, PNG image
(↔ `CF_DIBV5`), file lists (via the shared folder: files are staged in a
host temp directory that is visible to the guest, and vice versa).

## Host-side validation rules (the guest is untrusted)

- Rectangles are clamped to display/atlas bounds; atlas rects outside the
  atlas texture are rejected; window count capped (e.g. 512).
- Strings are length-capped and treated as plain text everywhere they are
  shown (titles, notifications). No rich text, no markup.
- `OpenOnHost`: `http/https/mailto` URLs only by default, and only when the
  guest is foreground due to recent user input (within 2 s), otherwise ask.
  Paths must resolve inside a shared folder after symlink resolution.
- Bulk transfers have a declared size up front, a per-transfer cap, and
  a rate limit. Clipboard data is only sent to the guest while a guest window
  is key (and the reverse), unless the user disables that in settings.
- `ForegroundChanged` may not steal focus from a non-Seemless Mac app; it
  bounces the Dock icon instead.
- Icons are decoded with ImageIO in-process only after a size/format check.

## Guest tools ISO

`seemless-tools.iso` (volume label `SEEMLESS_TOOLS`), built by
`guest/tools/build.sh` into `build/guest-tools/` (WP4.3):

```
/install.cmd    installs or updates everything below (guest/tools/install.cmd); /update = started by the service
/uninstall.cmd  removes the agent service
/version.txt    tools version, e.g. "0.0.2 (8bc3fb59e430)"
/agent/         seemless-agent-svc.exe, seemless-agent.exe, install.cmd, uninstall.cmd, version.txt
/drivers/       only with build.sh --drivers <dir> (pnputil /add-driver /subdirs /install)
```

Not on it yet: `rules.toml` (Z2), redistributables (VC++, DirectX legacy,
WebView2: docs/10 Q7). Drivers stay opt-in until Q1/Q13 settle what may be
redistributed.

**Version.** The tools version is the agent's Hello build without the
binary name: `seemless-agent-svc 0.0.2 (8bc3fb59e430)` → `0.0.2
(8bc3fb59e430)` (workspace version + git rev, `+dirty` for an uncommitted
tree). `build-agent.sh` writes it to `version.txt`; the host compares it
with the running agent's Hello (`seemlessctl tools info`).

**Every new VM** gets the agent: `image build` (CLI and app) copies the
guest tools' `agent/` folder into Windows unless `--no-agent`, and
`firstboot.cmd` runs its `install.cmd`. The folder is found by
`GuestTools.locate()`: `$SEEMLESS_GUEST_TOOLS`, the app bundle's
`Resources/guest-tools`, or `build/guest-tools`; `--agent <dir>` overrides.

**Update flow** (`seemlessctl tools update --name <vm>`,
`VMManager.updateTools`):

1. Connect, read the installed version from the Hello; stop if it matches
   (unless `--force`).
2. Hot-plug the ISO over QMP as a USB CD-ROM (`usb-bot` + `scsi-cd`, ids
   `sltoolsbot`/`sltoolsdev`, node `sltools`), so Windows mounts it as a CD.
3. Send `UpdateTools { iso_volume_label: "SEEMLESS_TOOLS", version }`. The
   service validates both fields (label 1–32 of `A-Z a-z 0-9 _ -`, version
   1–64 printable ASCII), finds the drive by label, checks that its
   `version.txt` equals `version` and that `install.cmd` exists, then starts
   `cmd /c install.cmd /update` in its own process group (log:
   `%ProgramData%\Seemless\logs\tools-update.log`) and replies `Ack`.
   Until Windows has mounted the CD the reply is `Error INTERNAL "no volume
   labelled …"`; the host retries that for 30 s.
4. `install.cmd /update` waits 2 s (so the `Ack` reaches the host), stops
   the service (waiting up to 30 s for STOPPED; the service ends the
   session agent), renames the running `.exe`s to `.old` and copies the new
   ones (a rename works on a running image, so a slow session agent cannot
   block it; the copy is rolled back if it fails), then starts the service.
   The SCM does not kill a stopped service's child, so the script outlives
   the service it stops.
5. The new service sends `Hello`; the host reconnects until the Hello
   carries the new version (default 180 s), then unplugs the CD.

A driver update that needs a reboot is logged (pnputil exit 3010), not
forced. A quarantined VM with its agent connection off refuses updates.

## Host side: `AgentClient` (SeemlessKit)

- `AgentClient` (WP4.1): an actor that owns the control socket. It does
  framing, the Hello exchange, request/response correlation with timeouts
  (`request`, `guestInfo`), the heartbeat, and replies to guest requests
  (`reply(to:with:)`). It exposes two streams: `events` (guest events and
  guest requests, in order) and `states` (`ready`, `unresponsive`,
  `responsive`, `peerRestarted`, `closed`). Splitting events per family is
  left to the consumers (`WindowModel` etc.). The bulk socket comes with
  the first bulk user (icons/clipboard).
- `seemlessctl agent hello|info [--socket <path> | --name <vm>]` talks to a
  VM's `agent.sock` or any socket.
- `WindowModel` (pure Swift, unit-tested): applies snapshot/add/update/remove
  into an ordered collection, resolves owner chains, emits diffs for the UI.
  The same recorded window dumps used for the Rust classifier tests should
  drive `WindowModel` tests.
- A **mock agent** (`seemlessctl mock-agent --socket <path> [--script
  file.json] [--once]`, `MockAgent` in SeemlessKit) speaks the protocol over
  a unix socket, so the whole window bridge can be developed and UI-tested
  on the Mac with no VM running. It follows the Hello rules and answers
  Pings and requests: a scripted reply, `Ack` for commands, or `Error
  UNSUPPORTED` for queries. Script steps:
  - `send` (an Envelope body in protobuf JSON),
  - `expect` (wait for a host message by name),
  - `sleepMs`,
  - `pings` (on/off, to test "agent lost"),
  - `hello` (simulate an agent restart),
  - `raw` (base64 bytes, to test hostile input),
  - `disconnect`.

  The format is on `MockAgentScript`; there is an example in
  `proto/mock/notepad.json`.
