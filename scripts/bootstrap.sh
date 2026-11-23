#!/usr/bin/env bash
# Check that this Mac has the tools Seemless needs.
#
# Usage: scripts/bootstrap.sh [--strict]
#
# Tools are grouped by the milestone that first needs them. By default only
# tools needed now (M0 scaffolding) are fatal; the rest are reported with the
# command that fixes them. --strict makes every missing tool fatal.
#
# This script only checks. It never installs anything or edits your shell
# configuration, because some installs need decisions only you can make
# (for example, xwin downloading Microsoft's SDK requires accepting
# Microsoft's licence).

set -uo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

fatal=0
warn=0

ok()   { printf '  \033[32mok\033[0m    %-22s %s\n' "$1" "$2"; }
bad()  { # name, detail, fix, required(1/0)
  if [[ "$4" == 1 || "$STRICT" == 1 ]]; then
    printf '  \033[31mFAIL\033[0m  %-22s %s\n' "$1" "$2"; fatal=$((fatal+1))
  else
    printf '  \033[33mwarn\033[0m  %-22s %s\n' "$1" "$2"; warn=$((warn+1))
  fi
  [[ -n "$3" ]] && printf '        %-22s fix: %s\n' "" "$3"
}
section() { printf '\n%s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- host
section "Host"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  bad "platform" "$(uname -sm)" "Seemless needs an Apple silicon Mac" 1
else
  ok "platform" "arm64, $(sysctl -n machdep.cpu.brand_string)"
fi
osv="$(sw_vers -productVersion)"
if (( ${osv%%.*} >= 26 )); then
  ok "macOS" "$osv (minimum 26, docs/01 D10)"
else
  bad "macOS" "$osv" "Seemless requires macOS 26 or later" 1
fi
mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if (( mem_gb < 16 )); then
  bad "memory" "${mem_gb} GB" "16 GB or more recommended (docs/10 R13)" 0
else
  ok "memory" "${mem_gb} GB"
fi
pcores=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "?")
ok "performance cores" "$pcores (default vCPU count, docs/02)"

# ---------------------------------------------------------------- M0: required now
section "Needed now (scaffolding, Swift package, agent logic tests)"
if xcode-select -p >/dev/null 2>&1 && have xcodebuild; then
  ok "Xcode" "$(xcodebuild -version 2>/dev/null | head -1) at $(xcode-select -p)"
else
  bad "Xcode" "not found" "install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" 1
fi
if have swift; then
  sv=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)
  if [[ "${sv%%.*}" -ge 6 ]]; then ok "swift" "$sv"; else bad "swift" "${sv:-unknown}" "Swift 6 or newer (Xcode 16+)" 1; fi
else
  bad "swift" "not found" "install Xcode" 1
fi

# Rust: the agent cross-compiles to Windows, which needs rustup-managed
# toolchains. A Homebrew `cargo` earlier on PATH ignores rust-toolchain.toml
# and rustup targets, so detect that case explicitly.
RUSTUP_CARGO="$HOME/.cargo/bin/cargo"
if have rustup && [[ -x "$RUSTUP_CARGO" ]]; then
  ok "rustup" "$(rustup --version 2>/dev/null | head -1)"
  first_cargo=$(command -v cargo)
  if [[ "$first_cargo" != "$RUSTUP_CARGO" ]]; then
    bad "cargo on PATH" "$first_cargo shadows rustup's cargo" \
      "put \$HOME/.cargo/bin before /opt/homebrew/bin in PATH, or 'brew uninstall rust'. Seemless scripts use $RUSTUP_CARGO directly" 0
  else
    ok "cargo on PATH" "$first_cargo"
  fi
else
  bad "rustup" "not found" "install from https://rustup.rs" 1
fi

# ---------------------------------------------------------------- M0 spikes / M1: host stack build
section "Needed for S1 (building QEMU and the graphics stack)"
for t in meson ninja cmake pkg-config git; do
  if have "$t"; then ok "$t" "$("$t" --version 2>&1 | head -1)"; else bad "$t" "not found" "brew install $t" 0; fi
done
LLVM15="$(brew --prefix llvm@15 2>/dev/null)"
if [[ -n "$LLVM15" && -x "$LLVM15/bin/clang" ]]; then
  ok "llvm@15" "$LLVM15 (DXMT needs exactly LLVM 15)"
else
  bad "llvm@15" "not found" "brew install llvm@15  (DXMT needs exactly major version 15)" 0
fi
if xcrun -f metal >/dev/null 2>&1; then
  ok "Metal toolchain" "$(xcrun -f metal)"
else
  bad "Metal toolchain" "not found" "xcodebuild -downloadComponent MetalToolchain" 0
fi
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  ok "Rosetta" "available (only the optional D3DMetal backend needs it)"
else
  bad "Rosetta" "not installed" "softwareupdate --install-rosetta  (optional: D3DMetal only)" 0
fi

# ---------------------------------------------------------------- M4: guest agent
section "Needed for M4 (guest agent for Windows on ARM)"
if have rustup && rustup target list --installed 2>/dev/null | grep -qx aarch64-pc-windows-msvc; then
  ok "rust target" "aarch64-pc-windows-msvc"
else
  bad "rust target" "aarch64-pc-windows-msvc not installed" "rustup target add aarch64-pc-windows-msvc" 0
fi
if [[ -x "$HOME/.cargo/bin/cargo-xwin" ]] || have cargo-xwin; then
  ok "cargo-xwin" "found"
else
  bad "cargo-xwin" "not found" "$RUSTUP_CARGO install --locked cargo-xwin  (its first build downloads Microsoft's CRT/SDK and asks you to accept Microsoft's licence)" 0
fi
if have protoc; then ok "protoc" "$(protoc --version)"; else bad "protoc" "not found" "brew install protobuf  (Swift codegen in WP4.1)" 0; fi

# ---------------------------------------------------------------- summary
printf '\n'
if (( fatal > 0 )); then
  printf '\033[31m%d required tool(s) missing.\033[0m %d warning(s).\n' "$fatal" "$warn"
  exit 1
fi
printf '\033[32mReady for current work.\033[0m %d warning(s) for later milestones.\n' "$warn"
