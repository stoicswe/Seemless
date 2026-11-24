#!/usr/bin/env bash
# Signs a release Seemless.app inside-out with the hardened runtime (WP8.2).
#
#   SEEMLESS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#     scripts/release/sign-app.sh build/release/Seemless.app
#
# Without SEEMLESS_SIGN_IDENTITY it signs ad-hoc ("-"), still with the
# hardened runtime, so local runs behave like the release (DYLD_* ignored,
# libraries found by rpath only). Ad-hoc signatures have no Team ID, so
# library validation would refuse every bundled dylib; ad-hoc builds alone
# add com.apple.security.cs.disable-library-validation to temporary copies
# of the entitlements. Ad-hoc apps cannot be notarized and Gatekeeper
# rejects them on other Macs. The identity is a certificate name in the owner's keychain;
# this script never reads keys or passwords (codesign asks the keychain).
#
# Order (inside-out): Frameworks/*.dylib, then Helpers/* (QEMU with
# app/Entitlements/qemu.entitlements), then the bundle itself.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:?usage: sign-app.sh <Seemless.app>}"
identity="${SEEMLESS_SIGN_IDENTITY:--}"
ents="$repo/app/Entitlements"

flags=(--force --options runtime)
if [[ "$identity" == "-" ]]; then
  echo "sign: ad-hoc (set SEEMLESS_SIGN_IDENTITY for a Developer ID signature)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  for e in qemu app; do
    cp "$ents/$e.entitlements" "$tmp/$e.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$tmp/$e.entitlements" >/dev/null
  done
  ents="$tmp"
else
  flags+=(--timestamp)
  echo "sign: $identity"
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
echo "sign: verified $(codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"
