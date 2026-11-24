#!/usr/bin/env bash
# Fails unless every Mach-O in a Seemless.app is self-contained (WP8.1).
#
#   scripts/release/audit-bundle.sh [--allow-newer-minos] build/release/Seemless.app
#
# For each Mach-O file in the bundle it checks, with otool:
#   - arm64 only, minimum macOS no newer than the app's LSMinimumSystemVersion;
#   - every load command (LC_LOAD_DYLIB and friends) is a system library
#     (/usr/lib, /System/Library) or @rpath/@loader_path/@executable_path,
#     and every @rpath/<leaf> is a file in Contents/Frameworks;
#   - every LC_RPATH is relative (@executable_path / @loader_path);
#   - dylib install names are @rpath/<leaf>;
#   - no load command or rpath names build/prefix, the repository, a home
#     directory or Homebrew.
# Prints one line per file and a summary; exits 1 on any failure.
#
# --allow-newer-minos reports a too-new minimum macOS as a warning instead
# (local testing only: such a bundle does not run on the oldest supported
# macOS, so it must not be released).
set -euo pipefail

allow_minos=0
if [[ "${1:-}" == --allow-newer-minos ]]; then allow_minos=1; shift; fi
app="${1:?usage: audit-bundle.sh [--allow-newer-minos] <Seemless.app>}"
app="$(cd "$app" && pwd)"
contents="$app/Contents"
fw="$contents/Frameworks"
minos_limit="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$contents/Info.plist" 2>/dev/null || echo 26.0)"

fail=0
warn=0
files=0
problem() { echo "  FAIL $1"; fail=$((fail + 1)); }
minos_problem() {
  if [[ $allow_minos == 1 ]]; then echo "  WARN $1"; warn=$((warn + 1)); else problem "$1"; fi
}

version_gt() { # a > b for dotted versions
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]
}

while IFS= read -r -d '' f; do
  head -c 4 "$f" 2>/dev/null | xxd -p | grep -qE '^(cffaedfe|cafebabe|feedfacf)$' || continue
  files=$((files + 1))
  rel="${f#"$app"/}"
  echo "$rel"
  archs="$(lipo -archs "$f" 2>/dev/null || echo '?')"
  [[ "$archs" == "arm64" ]] || problem "architectures: $archs (want arm64)"
  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
  if [[ -n "$minos" ]] && version_gt "$minos" "$minos_limit"; then minos_problem "minos $minos > LSMinimumSystemVersion $minos_limit"; fi

  cmd=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      "cmd "*) cmd="${line#cmd }" ;;
      "name "*|"path "*)
        value="${line#* }"; value="${value% (offset*}"
        case "$cmd" in
          LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_LAZY_LOAD_DYLIB|LC_LOAD_UPWARD_DYLIB)
            case "$value" in
              /usr/lib/*|/System/Library/*) ;;
              @rpath/*)
                leaf="${value#@rpath/}"
                [[ -f "$fw/$leaf" ]] || problem "$value: not in Contents/Frameworks"
                echo "  -> $value" ;;
              @loader_path/*|@executable_path/*)
                base="$(dirname "$f")"; [[ "$value" == @executable_path/* ]] && base="$contents/MacOS"
                [[ -e "$base/${value#@*_path/}" ]] || problem "$value: does not resolve inside the bundle"
                echo "  -> $value" ;;
              *) problem "load command $value" ;;
            esac ;;
          LC_ID_DYLIB)
            [[ "$value" == "@rpath/$(basename "$f")" ]] || problem "install name $value (want @rpath/$(basename "$f"))" ;;
          LC_RPATH)
            case "$value" in
              @executable_path/*|@loader_path|@loader_path/*) echo "  rpath $value" ;;
              *) problem "rpath $value" ;;
            esac ;;
        esac
        case "$value" in
          *build/prefix*|*/Github/*|/Users/*|/opt/homebrew/*|/usr/local/*) problem "points outside the bundle: $value" ;;
        esac ;;
    esac
  done < <(otool -l "$f")
done < <(find "$app" -type f -print0 | sort -z)

echo "audit: $files Mach-O files, $fail problems, $warn warnings"
if [[ $warn -gt 0 ]]; then echo "audit: NOT RELEASABLE: $warn files need a newer macOS than $minos_limit"; fi
[[ $fail -eq 0 ]]
