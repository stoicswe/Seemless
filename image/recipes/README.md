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
- Missing entries are skipped, not fatal, so one recipe works across builds.
- Keep the gaming/compatibility list in docs/03 ("keeps"): WOW64/Prism,
  servicing, Store, App Installer, WebView2 runtime, VC libs, .NET.
- Tiny11 Builder (no licence) is a behavioural reference only: do not copy
  its code or lists verbatim.

`seemless-default/` is intentionally empty until WP2.3: spike S4 first proves
that a plain, unmodified install works end to end.
