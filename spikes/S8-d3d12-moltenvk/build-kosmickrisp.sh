#!/bin/sh
# S8 spike: build Mesa's KosmicKrisp Vulkan driver (and only it) into
# build/s8/kk-prefix, with its OpenCL kernel toolchain built locally:
#   SPIRV-Headers + SPIRV-LLVM-Translator + libclc → build/s8/clc-prefix.
# Nothing is installed system-wide. Uses the Homebrew llvm in deps.lock.
# Sources are expected in build/src/{mesa,spirv-llvm-translator,spirv-headers,llvm-libclc}
# at the SHAs in deps.lock (fetch them by hand; each was approved separately).
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
spike="$repo/spikes/S8-d3d12-moltenvk"
b="$repo/build"
P="$b/s8/clc-prefix"
L=/opt/homebrew/opt/llvm/bin
mt="-mmacosx-version-min=26.0"

"$spike/check-deps.sh" || { [ "${S8_UNLOCKED:-0}" = 1 ] || exit 1; }

# 1. SPIRV-LLVM-Translator (static), against the exact SPIRV-Headers it pins.
cmake -S "$b/src/spirv-llvm-translator" -B "$b/s8/spirv-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
    -DLLVM_DIR=/opt/homebrew/opt/llvm/lib/cmake/llvm -DLLVM_SPIRV_INCLUDE_TESTS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR="$b/src/spirv-headers"
ninja -C "$b/s8/spirv-build" install

# 2. libclc, one configure per target. Needs Homebrew clang (Apple clang has
#    no SPIR-V target) and llvm-ar/ranlib (Apple's cannot archive bitcode, and
#    silently produce empty libraries).
for a in spirv32 spirv64; do
    cmake -S "$b/src/llvm-libclc/libclc" -B "$b/s8/libclc-$a" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
        -DCMAKE_C_COMPILER=$L/clang -DCMAKE_CXX_COMPILER=$L/clang++ -DCMAKE_CLC_COMPILER=$L/clang \
        -DCMAKE_AR=$L/llvm-ar -DCMAKE_RANLIB=$L/llvm-ranlib \
        -DCMAKE_CLC_COMPILER_AR=$L/llvm-ar -DCMAKE_CLC_COMPILER_RANLIB=$L/llvm-ranlib \
        -DLLVM_DIR=/opt/homebrew/opt/llvm/lib/cmake/llvm \
        -DLLVM_DEFAULT_TARGET_TRIPLE=$a-unknown-unknown -DLLVM_SPIRV="$P/bin/llvm-spirv"
    ninja -C "$b/s8/libclc-$a"
done
# LLVM 23 libclc installs no pkg-config file and uses new names; give Mesa
# the layout it expects.
mkdir -p "$P/share/clc" "$P/lib/pkgconfig"
cp "$b/s8/libclc-spirv32/spirv32-unknown-unknown/libclc.spv" "$P/share/clc/spirv-mesa3d-.spv"
cp "$b/s8/libclc-spirv64/spirv64-unknown-unknown/libclc.spv" "$P/share/clc/spirv64-mesa3d-.spv"
cat > "$P/lib/pkgconfig/libclc.pc" <<EOF
prefix=$P
libexecdir=\${prefix}/share/clc
Name: libclc
Description: libclc spirv32/spirv64 built from llvm-project llvmorg-23.1.5 (S8)
Version: 23.1.5
Cflags:
Libs:
EOF

# 3. Mesa: KosmicKrisp only.
export PATH="$b/venv/bin:$L:/opt/homebrew/opt/bison/bin:$PATH"
export PKG_CONFIG_PATH="$P/lib/pkgconfig"
rm -rf "$b/s8/mesa-build"
(cd "$b/src/mesa" && meson setup "$b/s8/mesa-build" --buildtype=release \
    --prefix="$b/s8/kk-prefix" -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= \
    -Dplatforms=macos -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false \
    -Dgles1=disabled -Dgles2=disabled -Dllvm=enabled -Dshared-llvm=disabled \
    -Dc_args="$mt" -Dcpp_args="$mt" -Dobjc_args="$mt" \
    -Dc_link_args="$mt -L/opt/homebrew/lib" -Dcpp_link_args="$mt -L/opt/homebrew/lib")
ninja -C "$b/s8/mesa-build" install
echo "KosmicKrisp ICD: $(find "$b/s8/kk-prefix" -name '*kosmickrisp*.json' | head -1)"
