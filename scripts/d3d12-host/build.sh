#!/usr/bin/env bash
# Build the WP7.5 D3D12 host test into build/wp75/bin/d3d12hosttest.
# Needs `scripts/build-deps.sh vkd3d` first (headers in build/prefix, the
# directx-native checkout in build/src). Run:
#   build/wp75/bin/d3d12hosttest build/prefix/lib/libvkd3d-proton-d3d12.dylib
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DXN="$ROOT/build/src/directx-native"
OUT="$ROOT/build/wp75/bin"
mkdir -p "$OUT" "$ROOT/build/wp75/gen"
python3 -I "$ROOT/scripts/d3d12-host/extract-dxil.py" "$ROOT/build/src/vkd3d-proton-npt" "$ROOT/build/wp75/gen/rung3_shaders.h" >/dev/null
[[ -f "$ROOT/build/prefix/include/vkd3d-proton/vkd3d_d3d12.h" ]] \
  || { echo "error: run scripts/build-deps.sh vkd3d first" >&2; exit 1; }
# directx-native is compiled in, so the test owns a separate copy of the
# event code, as DXMT does inside QEMU.
clang -std=gnu11 -O1 -g -mmacosx-version-min=26.0 -Wall -Wno-unused-function \
  -I"$ROOT/build/prefix/include/vkd3d-proton" -I"$DXN/include" -I"$DXN/src" \
  -I"$ROOT/guest/tools/d3d12test" -I"$ROOT/build/wp75/gen" \
  "$(dirname "$0")/d3d12hosttest.c" "$DXN/src/dxn_event_kqueue.c" "$DXN/src/dxn_log.c" \
  -o "$OUT/d3d12hosttest"
echo "built $OUT/d3d12hosttest"
