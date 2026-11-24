# Recorded window dumps

Test data for the `windows-model` classifier (WP5.1, docs/05 "Which windows
are mirrored"). `tests/dumps.rs` loads every file here and checks each
window's classification against its `expect` fields.

**All ten dumps are synthetic** (`"origin": "synthetic"`): there was no
Windows VM when they were written (2026-11-24). Each was written by hand
from how that app is known to build its top-level windows (class names,
styles, owners, cloaking). Handles, pids and rectangles are made up. Replace
them, or add captured ones next to them, once the agent runs in a guest
(see "Capturing" below).

| File | Shows |
|------|-------|
| `notepad.json` | Windows 11 Notepad: maximised and minimised windows, a XAML menu flyout, IME helpers |
| `explorer.json` | File Explorer, the WinUI and classic context menus, a window on another virtual desktop, the shell (taskbar, desktop, Start, Search) |
| `file-open.json` | The common file dialog (`#32770`) owned by Registry Editor, its tooltip and dropdown |
| `settings-uwp.json` | Settings in `ApplicationFrameHost`, a suspended UWP app, a frame still starting, a toast |
| `terminal.json` | Windows Terminal with a dropdown, ConPTY's hidden `PseudoConsoleWindow`, the cloaked XAML core window |
| `electron-vscode.json` | VS Code: Chromium widget windows, a no-activate tooltip, hidden, zero-size and off-screen helpers |
| `steam-custom-chrome.json` | Steam-style custom chrome: frameless resizable `WS_POPUP` app windows, a frameless menu |
| `console.json` | Classic `conhost` consoles (one minimised) and an unowned message box |
| `office-dialogs.json` | Word-style owned dialogs, a dialog owned by a dialog, ribbon tooltips |
| `splash.json` | A tool-window splash before its main form shows, Office's `MsoSplash`, a Delphi app owned by a hidden `TApplication` |

## Format (`seemless-window-dump/1`)

JSON, one object:

| Key | Meaning |
|-----|---------|
| `format` | `"seemless-window-dump/1"` |
| `origin` | `"synthetic"` (hand-written; `note` must say "Not captured") or `"captured"` |
| `app` | What the dump shows |
| `note`, `windows_build`, `captured_at` | Optional |
| `display` | `{rect, work_area}` of guest display 1, in pixels |
| `windows` | Top-level windows **front to back** (the `EnumWindows` order), hidden ones included |

Each window holds the raw fields (`RawWindow` in `src/raw.rs` lists the
Win32 call behind each one) and, in test data, the expectations:

| Key | Meaning |
|-----|---------|
| `hwnd`, `owner` | `"0x…"` strings; `owner` absent = none (`GW_OWNER`) |
| `class`, `title` | Window class and text |
| `style`, `ex_style` | `"0x…"` strings (`GWL_STYLE`, `GWL_EXSTYLE`) |
| `pid`, `process`, `aumid` | Process id, image path, AppUserModelID (optional) |
| `cloaked` | `DWMWA_CLOAKED` (0, 1 app, 2 shell, 4 inherited); absent = 0 |
| `rect` | `DWMWA_EXTENDED_FRAME_BOUNDS` as `{x, y, w, h}` |
| `restore_rect` | Minimised windows only: `rcNormalPosition` |
| `expect` | `normal`, `dialog`, `menu`, `tooltip`, `popup`, `splash`, `tool`, or `ignore:hidden`, `ignore:cloaked`, `ignore:empty`, `ignore:offscreen`, `ignore:rule` |
| `expect_owner` | HWND of the expected mirrored owner (absent = none) |
| `expect_fullscreen` | `true` if the window should trigger game mode |
| `note` | What the window is |

Every window in a test dump needs an `expect`, so nothing is left unchecked.

## Capturing from a real guest

`Dump::capture(&mut source, app, build)` reads any `WindowSource` (the
agent's Win32 enumerator) into a dump with no expectations; `to_json()`
writes it. To turn a capture into a test:

1. Save it here as `<app>.json` and add the name to `APPS` in
   `tests/dumps.rs`.
2. Call `fill_expectations(&Rules::defaults())` (or fill them by hand), then
   **review every window**: a capture with expectations copied from the
   classifier proves nothing until a person has checked it.
3. Where the classifier is wrong, fix `rules.toml` or `src/classify.rs`, and
   update docs/05.

The session agent will expose capture as a diagnostic (WP4.2 or WP5.2:
`seemless-agent --dump-windows <file>` or a `RunCommand`); until then this
library call is the whole capture path.

## Mock-agent scripts

`examples/dump-to-mock.rs` turns a dump into a `seemlessctl mock-agent`
script with one `WindowSnapshot` of the classified windows, as the agent
would send it (`proto/mock/office-dialogs.json` was made this way).
