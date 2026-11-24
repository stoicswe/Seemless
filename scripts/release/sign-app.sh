#!/usr/bin/env bash
# Signs a release Seemless.app inside-out with the hardened runtime (WP8.2).
#
#   SEEMLESS_SIGN_IDENTITY="<certificate name>" scripts/release/sign-app.sh build/release/Seemless.app
#
# Three kinds of signature, all with the hardened runtime, so local runs
# behave like the release (DYLD_* ignored, libraries found by rpath only):
#   ad-hoc        no SEEMLESS_SIGN_IDENTITY. Runs on the Mac that built it.
#   self-signed   SEEMLESS_SIGN_IDENTITY names the certificate from
#                 scripts/release/make-signing-cert.sh (Preview 1, owner
#                 2026-11-24). Not notarizable; testers allow it once in
#                 System Settings (docs/release.md).
#   Developer ID  SEEMLESS_SIGN_IDENTITY="Developer ID Application: …".
#                 Timestamped and notarizable.
# Ad-hoc and self-signed code has no Apple Team ID, so library validation
# would refuse every bundled dylib ("different Team IDs"). For those two
# kinds only, com.apple.security.cs.disable-library-validation is added to
# temporary copies of the entitlements; Developer ID builds use
# app/Entitlements/*.entitlements unchanged. The hypervisor entitlement is
# not restricted, so it works with all three.
#
# The identity is a certificate name in the keychain; this script never
# reads keys or passwords (codesign asks the keychain). SEEMLESS_SIGN_KEYCHAIN
# points codesign at another keychain (tests only).
#
# Prints "sign: kind=<adhoc|self-signed|developer-id>" for package-release.sh.
#
# Order (inside-out): Frameworks/*.dylib, then Helpers/* (QEMU with
# app/Entitlements/qemu.entitlements), then the bundle itself.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:?usage: sign-app.sh <Seemless.app>}"
identity="${SEEMLESS_SIGN_IDENTITY:--}"
ents="$repo/app/Entitlements"

flags=(--force --options runtime)
[[ -n "${SEEMLESS_SIGN_KEYCHAIN:-}" ]] && flags+=(--keychain "$SEEMLESS_SIGN_KEYCHAIN")

# Which kind? Sign a scratch copy of one dylib and read its Team ID.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if [[ "$identity" == "-" ]]; then
  kind=adhoc
else
  probe="$(ls "$app"/Contents/Frameworks/*.dylib | head -1)"
  cp "$probe" "$tmp/probe.dylib"
  codesign "${flags[@]}" --sign "$identity" "$tmp/probe.dylib" 2>"$tmp/probe.err" \
    || { cat "$tmp/probe.err" >&2; echo "sign: cannot sign with \"$identity\"" >&2; exit 1; }
  team="$(codesign -dv "$tmp/probe.dylib" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [[ -n "$team" && "$team" != "not set" ]]; then kind=developer-id; else kind=self-signed; fi
fi
if [[ $kind == adhoc ]]; then echo "sign: kind=adhoc"; else echo "sign: kind=$kind identity=$identity"; fi

if [[ $kind == developer-id ]]; then
  flags+=(--timestamp)
else
  for e in qemu app; do
    cp "$ents/$e.entitlements" "$tmp/$e.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$tmp/$e.entitlements" >/dev/null
  done
  ents="$tmp"
fi

sign() { codesign "${flags[@]}" --sign "$identity" "$@"; }

shopt -s nullglob
for lib in "$app"/Contents/Frameworks/*.dylib; do sign "$lib"; done
for exe in "$app"/Contents/Helpers/*; do
  if [[ "$(basename "$exe")" == qemu-system-aarch64 ]]; then
    sign --entitlements "$ents/qemu.entitlements" "$exe"
  else
    sign --entitlements "$ents/app.entitlements" "$exe"
  fi
done
sign --entitlements "$ents/app.entitlements" "$app"

codesign --verify --strict --deep "$app"
echo "sign: verified $(codesign -dv --verbose=2 "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"
