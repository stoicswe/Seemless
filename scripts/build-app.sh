#!/usr/bin/env bash
# Builds Seemless.app from the SwiftPM package in app/ into build/app/.
#
#   scripts/build-app.sh            debug build
#   scripts/build-app.sh --release  release build
#   scripts/build-app.sh --open     build, then launch
#
# The app finds the host stack (build/prefix) and image assets (image/) by
# walking up from its own location, so run it from build/app/ inside the
# repository. Ad-hoc signed; real signing and the XPC helper are WP3.3.
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
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle" >/dev/null
echo "$bundle"
if [[ $open_after == 1 ]]; then open "$bundle"; fi
