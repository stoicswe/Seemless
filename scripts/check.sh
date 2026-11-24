#!/usr/bin/env bash
# Run every check that works on a Mac without a VM. CI runs this too.
#
# Usage: scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Use rustup's cargo even when Homebrew's comes first on PATH (see bootstrap.sh).
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
[[ -x "$CARGO" ]] || CARGO="$(command -v cargo)"
# ...and rustup's rustc: cargo runs `rustc` from PATH, and Homebrew's has no
# Windows target ("can't find crate for `core`").
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"

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

step "release scripts (syntax, THIRD_PARTY.md shipped table)"
for f in "$ROOT"/scripts/package-release.sh "$ROOT"/scripts/release/*.sh; do bash -n "$f"; done
for f in "$ROOT"/scripts/release/*.py; do python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f"; done
python3 -I "$ROOT/scripts/release/gen_notices.py" --check "$ROOT"
plutil -lint -s "$ROOT"/app/Entitlements/*.entitlements

# Cargo and rustup run inside guest/agent: rustup picks the toolchain from
# the current directory's rust-toolchain.toml (pinned 1.99.1, with the
# Windows target), not from --manifest-path.
step "cargo check + test (guest/agent, host target)"
(cd "$ROOT/guest/agent" && "$CARGO" check --workspace && "$CARGO" test --workspace)

if (cd "$ROOT/guest/agent" && rustup target list --installed 2>/dev/null) | grep -qx aarch64-pc-windows-msvc; then
  step "cargo check (guest/agent, aarch64-pc-windows-msvc)"
  (cd "$ROOT/guest/agent" && "$CARGO" check --workspace --target aarch64-pc-windows-msvc)
else
  step "cargo check (Windows target) skipped: rustup target add aarch64-pc-windows-msvc"
fi

printf '\nAll checks passed.\n'
