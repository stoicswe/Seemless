#!/usr/bin/env bash
# Fetch and build the host stack (docs/02 "Building the host stack").
#
# Usage:
#   scripts/build-deps.sh fetch                 # fetch every source in versions.lock
#   scripts/build-deps.sh [component ...]       # build components in order
#   scripts/build-deps.sh all                   # angle epoxy dxmt virgl libtpms swtpm qemu moltenvk vkd3d
#   scripts/build-deps.sh --force <component>   # rebuild even if stamped done
#
# Layout (all gitignored):
#   build/src/<name>      sources checked out at the pinned SHA
#   build/prefix          install root: bin/ lib/ libexec/ share/
#   build/logs/<step>.log full output of each step
#   build/stamps/<name>   marks a finished component
#
# Recipe follows UTM's Triton build notes (docs/11). Deviations are marked
# DEVIATION and listed in docs/spikes/S1-host-stack-build.md.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/src"
PREFIX="$BUILD/prefix"
LOGS="$BUILD/logs"
STAMPS="$BUILD/stamps"
LOCK="$ROOT/scripts/versions.lock"
mkdir -p "$SRC" "$PREFIX" "$LOGS" "$STAMPS"

BREW="$(brew --prefix)"
LLVM15="$(brew --prefix llvm@15)"
ANGLE_INC="$SRC/webkit-angle/Source/ThirdParty/ANGLE/include"
ANGLE_LIB="$PREFIX/ANGLE.xcarchive/Products/usr/local/lib"
JOBS="$(sysctl -n hw.ncpu)"

# Seemless supports macOS 26 and later (docs/01 D10). Without this, clang
# defaults to the build machine's SDK version and the binaries refuse to run
# on older systems. ANGLE sets its own target (see build_angle).
export MACOSX_DEPLOYMENT_TARGET=26.0

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$BREW/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Python build-time modules (virglrenderer's gallium codegen needs PyYAML).
# A private venv keeps the system/Homebrew Python untouched.
VENV="$BUILD/venv"
PY_REQS=(pyyaml==6.0.3)
if [[ ! -x "$VENV/bin/python3" ]] || ! "$VENV/bin/python3" -c 'import yaml' 2>/dev/null; then
  python3 -m venv "$VENV"
  "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "${PY_REQS[@]}"
fi

export PATH="$PREFIX/bin:$VENV/bin:$PATH"

FORCE=0

log()  { printf '\033[1m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run <logname> <cmd...>: run a step, keep full output in build/logs.
run() {
  local name="$1"; shift
  log "  $name  (log: build/logs/$name.log)"
  if ! "$@" >"$LOGS/$name.log" 2>&1; then
    tail -40 "$LOGS/$name.log" >&2
    die "step '$name' failed; full log: $LOGS/$name.log"
  fi
}

lock_field() { # lock_field <name> <1=url|2=ref|3=sha>
  awk -v n="$1" -v f="$2" '$1 == n { print $(f+1); found=1 } END { if (!found) exit 1 }' "$LOCK" \
    || die "'$1' not in versions.lock"
}

# fetch <name> [sparse paths...]: shallow fetch of exactly the pinned SHA.
fetch() {
  local name="$1"; shift
  local url sha dir
  url="$(lock_field "$name" 1)"; sha="$(lock_field "$name" 3)"; dir="$SRC/$name"
  if [[ -d "$dir/.git" ]] && [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$sha" ]]; then
    log "fetch $name: already at ${sha:0:12}"; return
  fi
  log "fetch $name @ ${sha:0:12}"
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  if (( $# > 0 )); then
    git -C "$dir" sparse-checkout set --no-cone "${@}"
    run "fetch-$name" git -C "$dir" fetch --depth 1 --filter=blob:none origin "$sha"
  else
    run "fetch-$name" git -C "$dir" fetch --depth 1 origin "$sha"
  fi
  run "checkout-$name" git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  if [[ -f "$dir/.gitmodules" ]]; then
    run "submodules-$name" git -C "$dir" submodule update --init --recursive --depth 1
  fi
}

done_already() { [[ $FORCE == 0 && -f "$STAMPS/$1" ]] && log "$1: done (stamp), skipping" ; }
stamp() { git -C "$SRC/$2" rev-parse HEAD >"$STAMPS/$1"; log "$1: done"; }

# apply_patches <name>: apply every patches/<name>/*.patch to $SRC/<name>,
# idempotently. Skips a patch already applied (so a re-run or a skipped fetch is
# safe); fails loudly if a patch no longer matches the pinned source. Patches
# are small, upstream-ready fixes kept with the source (CLAUDE.md).
apply_patches() {
  local name="$1"; local dir="$SRC/$name"; local pdir="$ROOT/patches/$name" p
  [[ -d "$pdir" ]] || return 0
  for p in "$pdir"/*.patch; do
    [[ -e "$p" ]] || continue
    if git -C "$dir" apply --reverse --check "$p" >/dev/null 2>&1; then
      log "patch ${name}/$(basename "$p"): already applied"
    elif git -C "$dir" apply --check "$p" >/dev/null 2>&1; then
      run "patch-${name}-$(basename "$p" .patch)" git -C "$dir" apply "$p"
    else
      die "patch ${name}/$(basename "$p") does not apply to pinned $name"
    fi
  done
}

# ------------------------------------------------------------------ components

build_angle() {
  done_already angle && return
  fetch webkit-angle /Source/ThirdParty/ANGLE/ /Configurations/ /Tools/ccache/
  # DEVIATIONS for Xcode 27 (UTM's notes predate it):
  # - MACOSX_DEPLOYMENT_TARGET=12.0, not 11.0: Xcode 27 rejects < 12.0.
  #   Not 14.0 or our real minimum of 26.0: WebKit's CommonBase.xcconfig then
  #   adds -D_LIBCPP_ENABLE_ASSERTIONS, which the macOS 27 SDK's libc++
  #   rejects. A 12.0 build runs on 26+, which is all we need.
  # - GCC_TREAT_WARNINGS_AS_ERRORS=NO: the newer clang flags
  #   -Wshift-count-overflow in src/common/bitset_utils.h inside a branch
  #   that is dead for 64-bit sets.
  ( cd "$SRC/webkit-angle/Source/ThirdParty/ANGLE"
    run angle-archive xcodebuild archive \
      -archivePath "$PREFIX/ANGLE" -scheme ANGLE -sdk macosx -arch arm64 \
      -configuration Release WEBCORE_LIBRARY_DIR=/usr/local/lib \
      NORMAL_UMBRELLA_FRAMEWORKS_DIR="" CODE_SIGNING_ALLOWED=NO \
      MACOSX_DEPLOYMENT_TARGET=12.0 GCC_TREAT_WARNINGS_AS_ERRORS=NO )
  [[ -d "$ANGLE_LIB" ]] || die "ANGLE archive has no $ANGLE_LIB"
  stamp angle webkit-angle
}

build_epoxy() {
  done_already epoxy && return
  fetch libepoxy
  local s="$SRC/libepoxy"
  run epoxy-setup meson setup --wipe "$s/build" "$s" "-Dc_args=-I$ANGLE_INC" \
    -Degl=yes -Dx11=false -Dtests=false "--prefix=$PREFIX"
  run epoxy-install meson install -C "$s/build"
  stamp epoxy libepoxy
}

build_dxmt() {
  done_already dxmt && return
  [[ -x "$LLVM15/bin/clang" ]] || die "LLVM 15 missing: brew install llvm@15"
  fetch dxmt
  local s="$SRC/dxmt"
  run dxmt-setup meson setup --wipe "$s/build-native" "$s" \
    "-Dnative_llvm_path=$LLVM15" --buildtype=release "--prefix=$PREFIX"
  run dxmt-install meson install -C "$s/build-native"
  stamp dxmt dxmt
}

build_virgl() {
  done_already virgl && return
  fetch virglrenderer
  apply_patches virglrenderer
  local s="$SRC/virglrenderer"
  # Native arm64 only. DEVIATION: UTM also builds an x86_64 render server and
  # fuses both with lipo; that slice exists only for the optional D3DMetal
  # backend (docs/04) and is skipped here.
  run virgl-setup meson setup --wipe "$s/build-arm64" "$s" \
    "-Dc_args=-I$ANGLE_INC" -Dvenus=true -Dneptune=true \
    -Drender-server-worker=process -Dcheck-gl-errors=false \
    "--pkg-config-path=$PKG_CONFIG_PATH" "--prefix=$PREFIX"
  run virgl-install meson install -C "$s/build-arm64"
  stamp virgl virglrenderer
}

build_libtpms() {
  done_already libtpms && return
  fetch libtpms
  ( cd "$SRC/libtpms"
    run libtpms-autogen ./autogen.sh "--prefix=$PREFIX" --with-openssl --with-tpm2 \
      "CPPFLAGS=-I$BREW/opt/openssl@3/include" "LDFLAGS=-L$BREW/opt/openssl@3/lib"
    run libtpms-make make -j"$JOBS"
    run libtpms-install make install )
  stamp libtpms libtpms
}

build_swtpm() {
  done_already swtpm && return
  fetch swtpm
  ( cd "$SRC/swtpm"
    run swtpm-autogen ./autogen.sh "--prefix=$PREFIX" --with-openssl --without-seccomp \
      "CPPFLAGS=-I$BREW/opt/openssl@3/include" "LDFLAGS=-L$BREW/opt/openssl@3/lib"
    run swtpm-make make -j"$JOBS"
    run swtpm-install make install )
  stamp swtpm swtpm
}

build_qemu() {
  done_already qemu && return
  fetch qemu
  apply_patches qemu   # 0001: ui/seemless display backend (docs/04, D4); 0002: hvf RAS regs (hibernate resume)
  local s="$SRC/qemu"
  mkdir -p "$s/build"
  ( cd "$s/build"
    run qemu-configure ../configure \
      "--extra-cflags=-I$ANGLE_INC" "--extra-ldflags=-L$ANGLE_LIB" \
      "--prefix=$PREFIX" --target-list=aarch64-softmmu
    run qemu-make make -j"$JOBS"
    run qemu-install make install )
  stamp qemu qemu
}

# MoltenVK from source with patches/moltenvk (S8 H3/H4). Built with its own
# Xcode projects; External/ is filled from our pinned checkouts instead of
# fetchDependencies (which would also clone demo-only repos) or the CMake
# build (whose CPM downloads itself). Installs lib/libMoltenVK.dylib, which
# vkd3d-proton loads directly (no Vulkan loader).
MVK_DEPS=(mvk-cereal mvk-vulkan-headers mvk-spirv-cross mvk-spirv-tools mvk-spirv-headers)
build_moltenvk() {
  done_already moltenvk && return
  fetch moltenvk
  local n; for n in "${MVK_DEPS[@]}"; do fetch "$n"; done
  apply_patches moltenvk
  local s="$SRC/moltenvk" ext="$SRC/moltenvk/External"
  mkdir -p "$ext"
  ln -sfn "$SRC/mvk-cereal" "$ext/cereal"
  ln -sfn "$SRC/mvk-vulkan-headers" "$ext/Vulkan-Headers"
  ln -sfn "$SRC/mvk-spirv-cross" "$ext/SPIRV-Cross"
  # SPIRV-Tools gets MoltenVK's pre-generated headers unpacked into it, so copy.
  rm -rf "$ext/SPIRV-Tools"
  rsync -a --exclude .git "$SRC/mvk-spirv-tools/" "$ext/SPIRV-Tools/"
  rsync -a --exclude .git "$SRC/mvk-spirv-headers/" "$ext/SPIRV-Tools/external/spirv-headers/"
  unzip -o -q -d "$ext/SPIRV-Tools" "$s/Templates/spirv-tools/build.zip"
  rm -rf "$ext/SPIRV-Tools/__MACOSX"
  # arm64 only; deployment target 26.0 (D10).
  local xc=(-destination generic/platform=macOS -configuration Release ARCHS=arm64
            ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=26.0)
  ( cd "$s"
    SKIP_PACKAGING=Y run moltenvk-extdeps xcodebuild build -project ExternalDependencies.xcodeproj \
      -scheme ExternalDependencies-macOS -derivedDataPath External/build/Intermediates/macOS "${xc[@]}"
    run moltenvk-extdeps-package env SKIP_PACKAGING= PROJECT_DIR=. CONFIGURATION=Release bash -c \
      '. ./Scripts/create_ext_lib_xcframeworks.sh && . ./Scripts/package_ext_libs_finish.sh'
    run moltenvk-build xcodebuild build -project MoltenVKPackaging.xcodeproj \
      -scheme "MoltenVK Package (macOS only)" "${xc[@]}" )
  local dylib="$s/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
  [[ -f "$dylib" ]] || die "MoltenVK build produced no $dylib"
  mkdir -p "$PREFIX/lib"
  cp "$dylib" "$PREFIX/lib/libMoltenVK.dylib"
  install_name_tool -id "@rpath/libMoltenVK.dylib" "$PREFIX/lib/libMoltenVK.dylib"
  stamp moltenvk moltenvk
}

# vkd3d-proton (osy neptune fork) as the NPT_D3D12_LIBRARY_PATH backend
# (WP7.5): lib/libvkd3d-proton-d3d12.dylib (+ d3d12core), on MoltenVK.
build_vkd3d() {
  done_already vkd3d && return
  fetch vkd3d-proton-npt
  fetch directx-native
  apply_patches vkd3d-proton-npt
  local s="$SRC/vkd3d-proton-npt" b="$BUILD/vkd3d-npt-build" rev dxmt_rev
  # Meson wrap: use our pinned checkout, never download (--wrap-mode=nodownload).
  rev="$(awk -F' = ' '$1 == "revision" { print $2 }' "$s/subprojects/directx-native.wrap")"
  [[ "$rev" == "$(lock_field directx-native 3)" ]] \
    || die "vkd3d-proton-npt's directx-native.wrap names $rev, versions.lock pins another"
  # patches/vkd3d-proton-npt/0002 signals DXMT-created events with our copy of
  # directx-native; that is only safe while both pin the same revision.
  if [[ -f "$SRC/dxmt/subprojects/directx-native.wrap" ]]; then
    dxmt_rev="$(awk -F' = ' '$1 == "revision" { print $2 }' "$SRC/dxmt/subprojects/directx-native.wrap")"
    [[ "$dxmt_rev" == "$rev" ]] \
      || die "DXMT pins directx-native $dxmt_rev but vkd3d-proton-npt pins $rev (see patch 0002)"
  fi
  rm -rf "$s/subprojects/directx-native"
  rsync -a --exclude .git "$SRC/directx-native/" "$s/subprojects/directx-native/"
  local m="-mmacosx-version-min=26.0"
  run vkd3d-setup meson setup --wipe "$b" "$s" --buildtype=release --wrap-mode=nodownload \
    -Denable_tests=false -Denable_extras=false --native-file "$s/build-widl.txt" \
    "-Dc_args=$m" "-Dcpp_args=$m" "-Dc_link_args=$m" "-Dcpp_link_args=$m" "--prefix=$PREFIX"
  run vkd3d-install meson install -C "$b"
  stamp vkd3d vkd3d-proton-npt
}

ORDER=(angle epoxy dxmt virgl libtpms swtpm qemu moltenvk vkd3d)

# ------------------------------------------------------------------ main
(( $# > 0 )) || { sed -n '2,17p' "$0"; exit 0; }
if [[ "$1" == "--force" ]]; then FORCE=1; shift; fi

if [[ "$1" == fetch ]]; then
  fetch webkit-angle /Source/ThirdParty/ANGLE/ /Configurations/ /Tools/ccache/
  for n in libepoxy dxmt virglrenderer libtpms swtpm qemu moltenvk "${MVK_DEPS[@]}" \
           vkd3d-proton-npt directx-native; do fetch "$n"; done
  exit 0
fi
[[ "$1" == all ]] && set -- "${ORDER[@]}"
for c in "$@"; do
  declare -F "build_$c" >/dev/null || die "unknown component '$c' (known: ${ORDER[*]})"
  log "== $c"
  "build_$c"
done
