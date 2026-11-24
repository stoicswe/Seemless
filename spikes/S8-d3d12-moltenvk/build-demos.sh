#!/bin/sh
# S8 spike: build the headless vkd3d-proton demos (triangle, gears), the
# d3d12caps tool and the Vulkan probe against an already-built vkd3d-proton
# (see README.md). Output: build/s8/bin/.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
spike="$repo/spikes/S8-d3d12-moltenvk"
src="$repo/build/src/vkd3d-proton"
bld="$repo/build/s8/vkd3d-build"
out="$repo/build/s8/bin"
gen="$bld/libs/vkd3d-common/libvkd3d_common.a.p"   # widl-generated headers
mkdir -p "$out/demo-src"

# Upstream demos, with the XCB backend swapped for demo_headless.h.
for f in triangle.c gears.c triangle_vs.h triangle_ps.h gears_vs.h gears_ps_flat.h gears_ps_smooth.h; do
    cp "$src/demos/$f" "$out/demo-src/$f"
done
sed 's|#include "demo_xcb.h"|#include "demo_headless.h"|' "$src/demos/demo.h" > "$out/demo-src/demo.h"
cp "$spike/demos/demo_headless.h" "$out/demo-src/"

inc="-I$spike/compat -I$out/demo-src -I$src/include -I$src/khronos/Vulkan-Headers/include -I$src/khronos/SPIRV-Headers/include -I$gen"
lib="-L$bld/libs/d3d12 -lvkd3d-proton-d3d12 -Wl,-rpath,$bld/libs/d3d12 -Wl,-rpath,$bld/libs/d3d12core"
cflags="-O1 -std=c11 -D_GNU_SOURCE -Wno-everything -mmacosx-version-min=26.0"

for d in triangle gears; do
    clang $cflags $inc "$out/demo-src/$d.c" $lib -lm -o "$out/$d"
done
clang $cflags $inc "$spike/demos/d3d12caps.c" $lib -o "$out/d3d12caps"
clang -O1 -I "$src/khronos/Vulkan-Headers/include" "$spike/probe/vkprobe.c" \
    -L/opt/homebrew/lib -lvulkan -Wl,-rpath,/opt/homebrew/lib -o "$out/vkprobe"
echo "built: $(ls "$out" | grep -v demo-src | tr '\n' ' ')"
