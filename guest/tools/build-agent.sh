#!/usr/bin/env bash
# Builds the guest agent for Windows ARM64 and stages the folder that
# `seemlessctl image build --agent <dir>` copies into the image (docs/06,
# WP4.2). The full tools ISO is WP4.3.
#
#   guest/tools/build-agent.sh [--out <dir>]     default: build/guest-tools/agent
#
# Needs: rustup's cargo, the aarch64-pc-windows-msvc target and cargo-xwin
# (scripts/bootstrap.sh). cargo-xwin's FIRST build downloads Microsoft's CRT
# and Windows SDK into ~/Library/Caches/cargo-xwin. cargo-xwin shows no
# licence prompt: running that first build is the acceptance of Microsoft's
# licence terms, so the owner runs it, never an automated session.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
OUT="$ROOT/build/guest-tools/agent"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "usage: $0 [--out <dir>]" >&2; exit 2 ;;
  esac
done
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
# ...and rustup's rustc: cargo runs `rustc` from PATH, and Homebrew's has no
# Windows target ("can't find crate for `core`").
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
TARGET=aarch64-pc-windows-msvc
# Only the ARM64 CRT/SDK (cargo-xwin defaults to x86_64 too).
export XWIN_ARCH="${XWIN_ARCH:-aarch64}"
# Homebrew's LLVM provides clang-cl, lld-link and llvm-lib for cargo-xwin.
[[ -d /opt/homebrew/opt/llvm/bin ]] && export PATH="/opt/homebrew/opt/llvm/bin:$PATH"

rev="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD -- guest/agent proto 2>/dev/null || rev="$rev+dirty"
export SEEMLESS_AGENT_REV="$rev"

"$CARGO" xwin build --manifest-path guest/agent/Cargo.toml --target "$TARGET" --release -p svc -p session

BIN="$ROOT/guest/agent/target/$TARGET/release"
mkdir -p "$OUT"
cp "$BIN/seemless-agent-svc.exe" "$BIN/seemless-agent.exe" "$OUT/"
# cmd.exe wants CRLF; the repo keeps LF (as image/winpe does).
for f in install.cmd uninstall.cmd; do
  perl -pe 's/\r?\n/\r\n/' "guest/tools/agent/$f" > "$OUT/$f"
done
version="$(sed -n 's/^version = "\(.*\)"/\1/p' guest/agent/Cargo.toml | head -1)"
printf 'seemless-agent %s (%s)\r\n' "$version" "$rev" > "$OUT/version.txt"
echo "staged in $OUT:"
ls -l "$OUT"
