#!/usr/bin/env bash
# Builds a self-contained, signed Seemless.app plus a dmg and zip (WP8.1,
# WP8.2, WP8.5). Runbook and the owner's one-time setup: docs/release.md.
#
#   scripts/package-release.sh                  ad-hoc signed, local testing
#   SEEMLESS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   SEEMLESS_NOTARY_PROFILE=seemless-notary \
#     scripts/package-release.sh                Developer ID + notarization
#
# Options:
#   --skip-notarize        sign with the identity but do not submit
#   --allow-newer-minos    let the audit pass when bundled libraries need a
#                          newer macOS than LSMinimumSystemVersion (local
#                          testing only; the output is marked NOT RELEASABLE)
#
# Steps: build the app (release) and seemlessctl, copy the bundle to
# build/release/, bundle the host stack from build/prefix
# (scripts/release/bundle_stack.py), copy image/ assets, write the
# third-party notices (gen_notices.py), audit with otool (audit-bundle.sh,
# fails the build), sign inside-out (sign-app.sh), make the dmg, notarize and
# staple when a notary profile is set, then the zip and SHA256SUMS.
#
# Secrets: none are read or stored here. The identity is a certificate name
# in the login keychain; the notary profile is a name created once with
# `xcrun notarytool store-credentials` (credentials stay in the keychain).
# Publishing the outputs is the owner's job.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
rel="$repo/scripts/release"
prefix="$repo/build/prefix"
out="$repo/build/release"
identity="${SEEMLESS_SIGN_IDENTITY:-}"
profile="${SEEMLESS_NOTARY_PROFILE:-}"
notarize=1
audit_flags=()
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) notarize=0 ;;
    --allow-newer-minos) audit_flags+=(--allow-newer-minos) ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ -x "$prefix/bin/qemu-system-aarch64" ]] || { echo "package: $prefix missing: run scripts/build-deps.sh all" >&2; exit 1; }
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$repo/kit/Sources/SeemlessKit/Seemless.swift")"
step() { printf '\n== %s\n' "$*"; }

step "build app and seemlessctl (release)"
"$repo/scripts/build-app.sh" --release >/dev/null
swift build --package-path "$repo/kit" -c release --product seemlessctl >/dev/null
ctl="$(swift build --package-path "$repo/kit" -c release --show-bin-path)/seemlessctl"

step "assemble build/release/Seemless.app"
mkdir -p "$out"
app="$out/Seemless.app"
# Leave an existing source offer (Seemless-*-sources/) alone.
rm -rf "$app" "$out"/Seemless-*.dmg "$out"/Seemless-*.zip "$out"/SHA256SUMS "$out"/audit.txt "$out"/notarize.txt
ditto "$repo/build/app/Seemless.app" "$app"
codesign --remove-signature "$app" 2>/dev/null || true
python3 -I "$rel/bundle_stack.py" "$prefix" "$app" --seemlessctl "$ctl"
mkdir -p "$app/Contents/Resources/image"
rsync -a --exclude 'recipes/inventory' --exclude '.DS_Store' "$repo/image/" "$app/Contents/Resources/image/"
python3 -I "$rel/gen_notices.py" "$repo" "$app" "$version"

step "audit"
"$rel/audit-bundle.sh" "${audit_flags[@]}" "$app" | tee "$out/audit.txt"
releasable=1
grep -q "NOT RELEASABLE" "$out/audit.txt" && releasable=0

step "sign"
SEEMLESS_SIGN_IDENTITY="${identity:--}" "$rel/sign-app.sh" "$app"

step "dmg"
dmg="$out/Seemless-$version.dmg"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Seemless.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Seemless $version" -srcfolder "$stage" -fs APFS -format UDZO -ov "$dmg"
if [[ -n "$identity" ]]; then codesign --force --timestamp --sign "$identity" "$dmg"; fi

if [[ -n "$identity" && -n "$profile" && $notarize == 1 ]]; then
  if [[ $releasable == 0 ]]; then
    echo "package: not notarizing: the audit marked this build NOT RELEASABLE" >&2
  else
    step "notarize (notarytool, profile $profile)"
    # Notarizing the dmg also notarizes the app inside it (tickets are per
    # code hash), so both can be stapled from one submission.
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait | tee "$out/notarize.txt"
    grep -q "status: Accepted" "$out/notarize.txt" || { echo "package: notarization not accepted (xcrun notarytool log <id> --keychain-profile $profile)" >&2; exit 1; }
    xcrun stapler staple "$dmg"
    xcrun stapler staple "$app"
    spctl --assess --type execute -vv "$app"
  fi
elif [[ -n "$identity" ]]; then
  echo "package: signed, not notarized (set SEEMLESS_NOTARY_PROFILE)"
else
  echo "package: ad-hoc signed: runs on this Mac only; not for publishing"
fi

step "zip and checksums"
zip="$out/Seemless-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
( cd "$out" && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" > SHA256SUMS )
du -sh "$app" "$dmg" "$zip"
[[ $releasable == 1 ]] || echo "package: NOT RELEASABLE (see audit.txt)"
echo "package: done. Source offer: scripts/release/source-archive.sh"
