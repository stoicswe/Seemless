#!/usr/bin/env bash
# Builds the source offer for a release (WP8.5): the exact source of every
# third-party component in Seemless.app, for publishing next to the release.
#
#   scripts/release/source-archive.sh [--out DIR]
#
# Output (default build/release/Seemless-<version>-sources/):
#   <name>-<sha12>.tar.gz           `git archive` of the SHA pinned in
#                                   scripts/versions.lock (checked against the
#                                   checkout in build/src/<name>)
#   <name>-<path>-<sha12>.tar.gz    each git submodule the build uses, at the
#                                   commit its superproject records
#   qemu-subprojects-<sha12>.tar.gz the meson subprojects QEMU's configure
#                                   downloaded (dtc, keycodemapdb, softfloat)
#   seemless-build-<version>.tar.gz patches/, scripts/build-deps.sh,
#                                   scripts/versions.lock, scripts/release/,
#                                   THIRD_PARTY.md: how the binaries were built
#   SOURCES.txt                     every file with its sha256 and origin
#
# Archives are made from the pinned commits, never from the patched working
# trees; the patches ship separately in seemless-build-*.tar.gz.
# Every library in the app is built from these pins (no Homebrew), so the
# offer is complete without network access. Uploading is the owner's job.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="$repo/build/src"
lock="$repo/scripts/versions.lock"
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$repo/kit/Sources/SeemlessKit/Seemless.swift")"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
out="${out:-$repo/build/release/Seemless-$version-sources}"

# Components in the app (THIRD_PARTY.md "Shipped in Seemless.app"), by
# versions.lock name, with optional path restriction and submodules to take.
#   name|subtree (empty = whole tree)|submodules (empty, "all", or paths;
#   a listed path also takes the submodules nested inside it)
components=(
  "qemu||roms/edk2 roms/ipxe"
  "virglrenderer||"
  "libepoxy||"
  "webkit-angle|Source/ThirdParty/ANGLE|"
  "dxmt||all"
  "vkd3d-proton-npt||all"
  "directx-native||"
  "moltenvk||"
  "mvk-spirv-cross||"
  "mvk-spirv-headers||"
  "mvk-spirv-tools||"
  "mvk-vulkan-headers||"
  "mvk-cereal||"
  "libtpms||"
  "swtpm||"
  "glib||"
  "gvdb||"
  "proxy-libintl||"
  "pcre2||"
  "json-glib||"
  "openssl||"
  "libslirp||"
  "pixman||"
  "libpng||"
  "libjpeg-turbo||"
)

rm -rf "$out"; mkdir -p "$out"
sums="$out/SOURCES.txt"
{
  echo "# Seemless $version: corresponding source for the third-party components in Seemless.app."
  echo "# file  sha256  origin"
} > "$sums"
record() { # file origin
  printf '%s  %s  %s\n' "${1#"$out"/}" "$(shasum -a 256 "$1" | cut -d' ' -f1)" "$2" >> "$sums"
}

pinned_sha() { awk -v n="$1" '$1 == n { print $4 }' "$lock"; }
pinned_url() { awk -v n="$1" '$1 == n { print $2 }' "$lock"; }

# Partial clones (webkit-angle is blob:none + sparse) must never fetch: the
# archive is made only from objects the build used.
export GIT_NO_LAZY_FETCH=1
archive() { # dir commit prefix outfile [subtree]
  local dir="$1" commit="$2" prefix="$3" file="$4" sub="${5:-}"
  if [[ -n "$sub" ]]; then
    # <commit>:<path> archives just that tree, so git never touches the
    # (unfetched) blobs elsewhere in a sparse partial clone.
    git -C "$dir" archive --format=tar --prefix="$prefix/$sub/" "$commit:$sub" | gzip -n -6 > "$file"
  else
    git -C "$dir" archive --format=tar --prefix="$prefix/" "$commit" | gzip -n -6 > "$file"
  fi
}

for entry in "${components[@]}"; do
  IFS='|' read -r name paths subs <<<"$entry"
  sha="$(pinned_sha "$name")"; url="$(pinned_url "$name")"
  dir="$src/$name"
  [[ -n "$sha" ]] || { echo "source-archive: $name not in versions.lock" >&2; exit 1; }
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  [[ "$head" == "$sha" ]] || { echo "source-archive: $dir is at ${head:-nothing}, versions.lock pins $sha (run scripts/build-deps.sh fetch)" >&2; exit 1; }
  file="$out/$name-${sha:0:12}.tar.gz"
  archive "$dir" "$sha" "$name" "$file" "$paths"
  record "$file" "$url $sha${paths:+ (subtree $paths)}"
  echo "source-archive: $name ${sha:0:12}"

  [[ -z "$subs" ]] && continue
  # Every submodule (recursive): "<path relative to $dir> <recorded sha>".
  while read -r sm_path sm_sha; do
    if [[ "$subs" != all ]]; then
      keep=0; for p in $subs; do [[ "$sm_path" == "$p" || "$sm_path" == "$p"/* ]] && keep=1; done
      [[ $keep == 1 ]] || continue
    fi
    sm_head="$(git -C "$dir/$sm_path" rev-parse HEAD)"
    [[ "$sm_head" == "$sm_sha" ]] || { echo "source-archive: $name/$sm_path is at $sm_head, superproject records $sm_sha" >&2; exit 1; }
    sm_url="$(git -C "$dir/$sm_path" remote get-url origin 2>/dev/null || echo '?')"
    sfile="$out/$name-$(echo "$sm_path" | tr '/' '-')-${sm_sha:0:12}.tar.gz"
    archive "$dir/$sm_path" "$sm_sha" "$name/$sm_path" "$sfile"
    record "$sfile" "$sm_url $sm_sha (submodule $name/$sm_path)"
    echo "source-archive:   $name/$sm_path ${sm_sha:0:12}"
  done < <(git -C "$dir" submodule foreach --quiet --recursive 'echo "$displaypath $sha1"')
done

# QEMU's meson subprojects: fetched by configure from the .wrap files in the
# pinned tree (each wrap names its revision), so they are not in git archive.
qsha="$(pinned_sha qemu)"
qsub="$out/qemu-subprojects-${qsha:0:12}.tar.gz"
( cd "$src/qemu" && tar --exclude .git -czf "$qsub" subprojects/berkeley-softfloat-3 subprojects/berkeley-testfloat-3 subprojects/dtc subprojects/keycodemapdb )
record "$qsub" "meson subprojects downloaded by QEMU $qsha configure (revisions in subprojects/*.wrap)"
echo "source-archive: qemu meson subprojects"

# How it was built: our patches and build scripts.
bfile="$out/seemless-build-$version.tar.gz"
( cd "$repo" && tar -czf "$bfile" patches scripts/build-deps.sh scripts/versions.lock scripts/release THIRD_PARTY.md )
record "$bfile" "Seemless patches/ and build scripts (apply patches/<name>/*.patch to each component; see scripts/build-deps.sh)"

du -sh "$out"
echo "source-archive: $out"
