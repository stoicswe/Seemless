# app

`Seemless.app`: for now a VM manager (WP3.0). SwiftUI, Liquid Glass,
macOS 26+. All logic is in `kit/` (`VMManager`, `ImageBuilder`); this target
only has views.

```bash
scripts/build-app.sh          # → build/app/Seemless.app (ad-hoc signed)
scripts/build-app.sh --open   # build and launch
SEEMLESS_ROOT=/tmp/x build/app/Seemless.app/Contents/MacOS/Seemless   # throwaway storage root
```

The app finds `build/prefix` (host stack) and `image/` by walking up from its
own location, so run it from `build/app/` inside the repository (or set
`SEEMLESS_PREFIX` / `SEEMLESS_IMAGE_ASSETS`).

| File | Contents |
|------|----------|
| `SeemlessApp.swift` | App, quit handling (shuts down VMs the app started), Machine menu |
| `AppModel.swift` | Observable state over `VMManager`, 1 s status polling, actions, install progress |
| `ContentView.swift` | Split view, sidebar, empty and "stack not built" states |
| `VMDetailView.swift` | Header, glass control cluster, Hardware / Boot & Firmware / Media / Snapshots / Files sections |
| `VMSettingsView.swift` | Settings sheet (read-only while running) |
| `NewVMView.swift` | ISO drop + inspection, sizing, automatic or manual install |
| `Components.swift` | `GlassSection` (shared `SectionMetrics`), status badge, ISO drop zone, formatting |

Built with SwiftPM until the XPC helper and entitlements (WP3.3) need an
Xcode project. VMs run as children of the app. "Start" gives QEMU its own
window, and "Show Display" brings it forward. "Start without Window" exports
the display; "Show Display" then opens the app's own desktop window
(`Display/DesktopWindow.swift`), which shows the whole guest screen live and
passes pointer and keys to the guest. It closes when the VM stops.
