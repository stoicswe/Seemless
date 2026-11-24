#!/bin/bash
# Spike S3: start S3Viewer for a run.sh workdir, commands via <workdir>/cmd (a FIFO).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; work="$1"
rm -f "$work/cmd"; mkfifo "$work/cmd"
( sleep 100000 > "$work/cmd" & echo $! > "$work/cmd.holder" )
"$HERE/.build/release/S3Viewer" "${@:2}" --service "app.seemless.s3.$(basename "$work")" --qmp "$work/qmp.sock" \
  --csv "$work/frames.csv" < "$work/cmd" > "$work/viewer.out" 2> "$work/viewer.err" &
echo $! > "$work/viewer.pid"
