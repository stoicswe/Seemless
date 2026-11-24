#!/usr/bin/env bash
# Run every check that works on a Mac without a VM. CI runs this too.
#
# Usage: scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Use rustup's cargo even when Homebrew's comes first on PATH (see bootstrap.sh).
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
[[ -x "$CARGO" ]] || CARGO="$(command -v cargo)"

step() { printf '\n== %s\n' "$1"; }

step "bootstrap"
"$ROOT/scripts/bootstrap.sh"

step "generated protocol types up to date (proto/ -> kit)"
CARGO="$CARGO" "$ROOT/scripts/gen-proto.sh" --check

step "swift build + test (kit)"
swift build --package-path "$ROOT/kit"
swift test --package-path "$ROOT/kit"

step "app bundle (SwiftUI, app/)"
"$ROOT/scripts/build-app.sh" >/dev/null

step "cargo check + test (guest/agent, host target)"
"$CARGO" check --manifest-path "$ROOT/guest/agent/Cargo.toml" --workspace
"$CARGO" test --manifest-path "$ROOT/guest/agent/Cargo.toml" --workspace

if rustup target list --installed 2>/dev/null | grep -qx aarch64-pc-windows-msvc; then
  step "cargo check (guest/agent, aarch64-pc-windows-msvc)"
  "$CARGO" check --manifest-path "$ROOT/guest/agent/Cargo.toml" --workspace --target aarch64-pc-windows-msvc
else
  step "cargo check (Windows target) skipped: rustup target add aarch64-pc-windows-msvc"
fi

printf '\nAll checks passed.\n'
