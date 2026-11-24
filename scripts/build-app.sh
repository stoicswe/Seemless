#!/usr/bin/env bash
# Builds Seemless.app from the SwiftPM package in app/ into build/app/.
#
#   scripts/build-app.sh            debug build
#   scripts/build-app.sh --release  release build
#   scripts/build-app.sh --open     build, then launch
#
# This is the development bundle: it finds the host stack (build/prefix) and
# image assets (image/) by walking up from its own location, so run it from
# build/app/ inside the repository. Ad-hoc signed.
#
# A self-contained, signed release app (QEMU, libraries, firmware and image
# assets inside the bundle) is scripts/package-release.sh, which starts from
# this script's --release output (docs/release.md).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
config=debug
open_after=0
for arg in "$@"; do
  case "$arg" in
    --release) config=release ;;
    --open) open_after=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

swift build --package-path "$repo/app" -c "$config"
bin="$(swift build --package-path "$repo/app" -c "$config" --show-bin-path)/Seemless"

version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$repo/kit/Sources/SeemlessKit/Seemless.swift")"
bundle="$repo/build/app/Seemless.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin" "$bundle/Contents/MacOS/Seemless"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.seemless.Seemless</string>
  <key>CFBundleName</key><string>Seemless</string>
  <key>CFBundleDisplayName</key><string>Seemless</string>
  <key>CFBundleExecutable</key><string>Seemless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- "Open in Seemless" (GuestLaunch): Open With for Windows installers,
       as an alternate handler so Seemless never becomes their default app. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Program</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.microsoft.windows-executable</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Installer Package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>msi</string><string>MSI</string></array>
    </dict>
  </array>
  <!-- Finder right-click > Services / Quick Actions > Open in Seemless -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Open in Seemless</string></dict>
      <key>NSMessage</key><string>openInSeemless</string>
      <key>NSPortName</key><string>Seemless</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key>
      <array><string>com.microsoft.windows-executable</string><string>com.microsoft.windows-installer</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle" >/dev/null
# Register with Launch Services so Finder offers Open With / the service.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$bundle" || true
/System/Library/CoreServices/pbs -update || true
echo "$bundle"
if [[ $open_after == 1 ]]; then open "$bundle"; fi
