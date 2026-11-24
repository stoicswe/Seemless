#!/bin/bash
# Spike S3: one latency run on the firmware front page.
#
#   measure.sh <label> cocoa|seemless [viewer args...]
#
# Boots firmware with build/s3's QEMU, goes to the front page (exit from the
# UEFI shell), finds the window, runs S3Latency (40 × Down/Up) and, for
# seemless, the viewer's own per-stage breakdown. Results: build/s3/results/<label>.txt
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
label="$1"; mode="$2"; shift 2
S3="$ROOT/build/s3"; work="$S3/m-$label"; out="$S3/results/$label.txt"
mkdir -p "$work" "$S3/results"
[[ -x "$S3/winid" ]] || swiftc -O "$S3/winid.swift" -o "$S3/winid"

( "$HERE/run.sh" "$mode" "$work" & )
sleep 1
if [[ "$mode" == seemless ]]; then "$HERE/view.sh" "$work" "$@"; fi
sleep 7
python3 -I "$S3/qmpkeys.py" "$work/qmp2.sock" esc; sleep 1.5
python3 -I "$S3/qmpkeys.py" "$work/qmp2.sock" e x i t ret
sleep 3
if [[ "$mode" == seemless ]]; then pid=$(cat "$work/viewer.pid"); else pid=$(pgrep -f "name s3-cocoa"); fi
wid=$("$S3/winid" "$pid" | head -1 | cut -d' ' -f1)
screencapture -x -o -l "$wid" "$work/window.png"
{
  echo "# $label ($mode $*) $(date)"
  "$HERE/.build/release/S3Latency" --window "$wid" --qmp "$work/qmp2.sock" --n "${N:-40}" --keys down,up
} > "$out" 2>&1
if [[ "$mode" == seemless ]]; then
  echo stats > "$work/cmd"; sleep 0.5; echo quit > "$work/cmd"; sleep 1
  cat "$work/viewer.out" >> "$out"
  kill "$(cat "$work/cmd.holder")" 2>/dev/null || true
fi
pkill -f "name s3-$mode" || true
sleep 2
cat "$out"
