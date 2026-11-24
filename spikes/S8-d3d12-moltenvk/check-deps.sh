#!/bin/sh
# S8 spike: verify the machine matches deps.lock (sources, submodules, brew,
# pip). Prints one line per mismatch; exit 1 if any.
set -u
repo=$(cd "$(dirname "$0")/../.." && pwd)
lock="$repo/spikes/S8-d3d12-moltenvk/deps.lock"
bad=0
miss() { echo "MISMATCH: $*"; bad=1; }

grep -v '^[[:space:]]*#' "$lock" | while read -r kind a b c d; do
    case "$kind" in
        source)
            want="$d"; dir="$repo/build/src/$a"
            [ -d "$dir/.git" ] || { echo "not fetched: $a (ok before fetch)"; continue; }
            have=$(git -C "$dir" rev-parse HEAD)
            [ "$have" = "$want" ] || miss "source $a at $have, lock says $want"
            # top-level pins must agree with scripts/versions.lock
            vl=$(awk -v n="$a" '$1==n{print $4}' "$repo/scripts/versions.lock")
            [ -z "$vl" ] || [ "$vl" = "$want" ] || miss "source $a: scripts/versions.lock says $vl"
            ;;
        submodule)
            dir="$repo/build/src/$a/$b"
            [ -d "$dir" ] || continue
            have=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
            [ "$have" = "$c" ] || miss "submodule $a/$b at $have, lock says $c"
            ;;
        brew)
            have=$(brew list --versions "$a" 2>/dev/null | awk '{print $NF}')
            [ "$have" = "$b" ] || miss "brew $a is '${have:-not installed}', lock says $b"
            ;;
        pip)
            py="$repo/build/venv/bin/python3"
            have=$("$py" -m pip show "$a" 2>/dev/null | awk '/^Version:/{print $2}')
            [ "$have" = "$b" ] || miss "pip $a is '${have:-not installed}', lock says $b"
            ;;
    esac
done | tee /dev/stderr | grep -q MISMATCH && exit 1
echo "deps.lock: all checked entries match"
exit 0
