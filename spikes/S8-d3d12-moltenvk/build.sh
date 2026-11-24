#!/bin/sh
# S8 spike: build vkd3d-proton natively for macOS arm64 (tests enabled).
#   fetch  shallow-clone vkd3d-proton at the SHA in scripts/versions.lock into
#          build/src/vkd3d-proton (with submodules) and apply the patch
#   setup  meson setup build/s8/vkd3d-build (deployment target 26.0, D10)
#   build  ninja
#   all    everything above (default)
# Needs the versions in deps.lock (checked by check-deps.sh before setup/build).
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
spike="$repo/spikes/S8-d3d12-moltenvk"
src="$repo/build/src/vkd3d-proton"
bld="$repo/build/s8/vkd3d-build"
step=${1:-all}

fetch() {
    sha=$(awk '$1=="vkd3d-proton"{print $4}' "$repo/scripts/versions.lock")
    url=$(awk '$1=="vkd3d-proton"{print $2}' "$repo/scripts/versions.lock")
    if [ ! -d "$src/.git" ]; then
        mkdir -p "$src"
        git -C "$src" init -q
        git -C "$src" remote add origin "$url"
        git -C "$src" fetch -q --depth 1 origin "$sha"
        git -C "$src" checkout -q FETCH_HEAD
        git -C "$src" submodule update --init --depth 1 --recursive
    fi
    if git -C "$src" apply --check "$spike/vkd3d-proton-macos.patch" 2>/dev/null; then
        git -C "$src" apply "$spike/vkd3d-proton-macos.patch"
    else
        echo "patch already applied (or does not apply cleanly); leaving tree as is"
    fi
}

setup() {
    flags="-I$spike/compat -mmacosx-version-min=26.0"
    rm -rf "$bld"
    (cd "$src" && meson setup "$bld" --buildtype=release -Denable_tests=true \
        --native-file build-widl.txt \
        -Dc_args="$flags" -Dcpp_args="$flags" \
        -Dc_link_args="-mmacosx-version-min=26.0" -Dcpp_link_args="-mmacosx-version-min=26.0")
}

build() { ninja -C "$bld"; }

lockcheck() {
    if ! "$spike/check-deps.sh" >/dev/null 2>&1; then
        "$spike/check-deps.sh"
        if [ "${S8_UNLOCKED:-0}" = 1 ]; then
            echo "S8_UNLOCKED=1: building despite deps.lock mismatches"
        else
            echo "deps.lock mismatch; fix it or set S8_UNLOCKED=1"; exit 1
        fi
    fi
}

case "$step" in
    fetch) fetch ;;
    setup) lockcheck; setup ;;
    build) lockcheck; build ;;
    all) fetch; lockcheck; setup; build ;;
    *) echo "usage: $0 [fetch|setup|build|all]"; exit 2 ;;
esac
