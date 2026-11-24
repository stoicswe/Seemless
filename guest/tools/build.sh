#!/usr/bin/env bash
# Builds seemless-tools.iso (docs/06 "Guest tools ISO", WP4.3):
#
#   /install.cmd     installs or updates everything below (guest/tools/install.cmd)
#   /uninstall.cmd   removes the agent service
#   /version.txt     tools version, e.g. "0.0.2 (8bc3fb59e430)"
#   /agent/          seemless-agent-svc.exe, seemless-agent.exe, agent\install.cmd ...
#   /drivers/        only with --drivers <dir> (ARM64 .inf folders)
#
#   guest/tools/build.sh [--skip-agent-build] [--drivers <dir>] [--out <dir>]
#
# Default output: build/guest-tools/ (staging folder iso/ and
# seemless-tools.iso). Volume label SEEMLESS_TOOLS: the agent service finds
# the update medium by it. The agent comes from build-agent.sh (needs
# cargo-xwin; see that script for the owner's one-time licence step).
#
# Redistributables (VC++, DirectX, WebView2) are not included: docs/10 Q7.
# Drivers are included only when asked for: their redistribution is Q1/Q13.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
OUT="$ROOT/build/guest-tools"
DRIVERS=""
BUILD_AGENT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-agent-build) BUILD_AGENT=0; shift ;;
    --drivers) DRIVERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "usage: $0 [--skip-agent-build] [--drivers <dir>] [--out <dir>]" >&2; exit 2 ;;
  esac
done
LABEL=SEEMLESS_TOOLS
AGENT="$OUT/agent"

if [[ $BUILD_AGENT == 1 ]]; then
  guest/tools/build-agent.sh --out "$AGENT"
fi
for f in seemless-agent-svc.exe seemless-agent.exe install.cmd version.txt; do
  [[ -f "$AGENT/$f" ]] || { echo "missing $AGENT/$f (run guest/tools/build-agent.sh)" >&2; exit 1; }
done

STAGE="$OUT/iso"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$AGENT" "$STAGE/agent"
cp "$AGENT/version.txt" "$STAGE/version.txt"
perl -pe 's/\r?\n/\r\n/' guest/tools/install.cmd > "$STAGE/install.cmd"
cp "$AGENT/uninstall.cmd" "$STAGE/uninstall.cmd"
if [[ -n "$DRIVERS" ]]; then
  [[ -d "$DRIVERS" ]] || { echo "no such folder: $DRIVERS" >&2; exit 1; }
  cp -R "$DRIVERS" "$STAGE/drivers"
fi

ISO="$OUT/seemless-tools.iso"
rm -f "$ISO"
# ISO 9660 + Joliet: Windows reads both; the label is the volume name.
hdiutil makehybrid -quiet -iso -joliet -default-volume-name "$LABEL" -o "$ISO" "$STAGE"
echo "tools $(tr -d '\r' < "$STAGE/version.txt") -> $ISO ($(du -h "$ISO" | cut -f1))"
