#!/usr/bin/env bash
# Build d3d12guesttest.exe (Windows ARM64) on the Mac, with no Microsoft SDK
# or CRT: Homebrew clang + llvm-dlltool, and rustup's rust-lld as the COFF
# linker. D3D12/DXGI types come from vkd3d-proton's installed headers
# (scripts/build-deps.sh vkd3d), with vkd3d_windows.h shadowed by an LLP64
# copy (Windows `long` is 32-bit). Output: build/wp75/guest/d3d12guesttest.exe
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
INC="$ROOT/build/prefix/include/vkd3d-proton"
OUT="$ROOT/build/wp75/guest"
SHIM="$OUT/shim"
LLVM="$(brew --prefix llvm)/bin"
LLD="$(ls ~/.rustup/toolchains/*/lib/rustlib/aarch64-apple-darwin/bin/rust-lld | head -1)"
[[ -f "$INC/vkd3d_d3d12.h" ]] || { echo "error: run scripts/build-deps.sh vkd3d first" >&2; exit 1; }
[[ -x "$LLD" ]] || { echo "error: rust-lld not found (rustup toolchain)" >&2; exit 1; }
mkdir -p "$SHIM" "$ROOT/build/wp75/gen"
python3 -I "$ROOT/scripts/d3d12-host/extract-dxil.py" "$ROOT/build/src/vkd3d-proton-npt" "$ROOT/build/wp75/gen/rung3_shaders.h" >/dev/null
# LLP64 shadow of vkd3d_windows.h (64-bit types must not use `long`).
sed -e 's/^typedef long INT64;/typedef long long INT64;/' \
    -e 's/^typedef unsigned long UINT64;/typedef unsigned long long UINT64;/' \
    -e 's/^typedef long LONG_PTR;/typedef long long LONG_PTR;/' \
    -e 's/^typedef unsigned long ULONG_PTR;/typedef unsigned long long ULONG_PTR;/' \
    "$INC/vkd3d_windows.h" > "$SHIM/vkd3d_windows.h"
grep -q 'typedef unsigned long long ULONG_PTR;' "$SHIM/vkd3d_windows.h" || { echo "error: LLP64 shim failed" >&2; exit 1; }
: > "$SHIM/stdlib.h"; : > "$SHIM/string.h"
for d in kernel32 d3d12 dxgi; do
  "$LLVM/llvm-dlltool" -m arm64 -d "$HERE/$d.def" -l "$OUT/$d.lib"
done
# -U_WIN32 selects the headers' portable (non-<windows.h>) path.
"$LLVM/clang" --target=aarch64-pc-windows-gnu -U_WIN32 -U_WIN64 -ffreestanding -fno-builtin \
  -fno-stack-protector -fno-stack-check -mno-stack-arg-probe -O1 -Wall -Wno-unused-function -Wno-macro-redefined \
  -I"$SHIM" -I"$INC" -I"$HERE" -I"$OUT/../gen" -c "$HERE/d3d12guesttest.c" -o "$OUT/d3d12guesttest.o"
"$LLD" -flavor link -nologo -subsystem:console -entry:start -nodefaultlib -machine:arm64 \
  -out:"$OUT/d3d12guesttest.exe" "$OUT/d3d12guesttest.o" "$OUT/kernel32.lib" "$OUT/d3d12.lib" "$OUT/dxgi.lib"
echo "built $OUT/d3d12guesttest.exe"
