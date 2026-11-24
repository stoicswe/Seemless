# image/recipes

A recipe is a directory read by `apply.cmd` inside WinPE (docs/03 "Recipe format").
Every file is optional; `#` starts a comment line.

| File | Meaning |
|------|---------|
| `remove-appx.txt` | Provisioned app **name prefixes**, one per line (e.g. `Clipchamp.Clipchamp`). Matched case-insensitively against `dism /Get-ProvisionedAppxPackages` |
| `remove-capabilities.txt` | Exact capability names for `dism /Remove-Capability` |
| `disable-features.txt` | Exact optional feature names for `dism /Disable-Feature` |
| `delete-paths.txt` | Paths relative to the Windows partition root, deleted after taking ownership |
| `registry/*.reg` | Imported with `reg import`. Address the offline hives as `HKEY_LOCAL_MACHINE\zSEEMLESS_SOFTWARE`, `zSEEMLESS_SYSTEM`, `zSEEMLESS_DEFAULT`, `zSEEMLESS_NTUSER` |

## Rules

- **Lists come from real images, never from memory.** Every `image build`
  writes `inventory-appx.txt`, `inventory-capabilities.txt` and
  `inventory-features.txt` from the actual ARM64 image into the build's
  result folder. Write the recipe from those (WP2.3), and keep the inventory
  that each entry was checked against under `inventory/<build>/`.
- Missing entries are skipped, not fatal, so one recipe works across builds:
  `apply.cmd` runs recipe steps through `:try`, which logs `WARNING exit N`
  and goes on; apps with no match log `skip appx <prefix>`.
- `RecipeTests` (kit) checks every entry against the newest inventory, the
  keep lists, offline-hive registry paths, and that `seemless-gaming` differs
  from `seemless-default` only by the gaming keeps. `.reg` files are ASCII
  (the payload converts line endings byte-wise; `reg import` accepts ANSI).
- Every build also writes `after-appx.txt`, `after-capabilities.txt` and
  `after-features.txt` once the recipe has run, so its effect is visible.
- Keep the gaming/compatibility list in docs/03 ("keeps"): WOW64/Prism,
  servicing, Store, App Installer, WebView2 runtime, VC libs, .NET.
- Tiny11 Builder (no licence) is a behavioural reference only: do not copy
  its code or lists verbatim.

## Recipes

| Recipe | For |
|--------|-----|
| `seemless-default` | Edge browser, consumer apps, Phone Link, widgets, Teams, Outlook, Xbox apps, a few legacy capabilities and enterprise features out; ads, suggestions, Copilot, chat auto-install, reserved storage and automatic BitLocker off; OneDrive installer deleted |
| `seemless-gaming` | Same, but keeps the Xbox apps and legacy Windows Media Player |
| `stock` | Empty: Windows exactly as on the ISO (the app's "Fat" profile) |

The app calls these profiles "Lean", "Lean, with Xbox" and "Fat"
(`InstallProfile` in kit); the install type and profile have no default in
the New VM sheet, so the person always chooses.

Reasons for every entry are comments in the list files. Both lean recipes
delete the Edge browser (owner decision 2026-11-23); EdgeWebView and
EdgeUpdate stay, and a policy stops EdgeUpdate reinstalling the browser.
Install another browser with "Open in Seemless" (docs/07).

Inventories: `inventory/26300.9457-pro-arm64/` (2026-11-23, Windows 11 Pro
ARM64 build 26300.9457).
