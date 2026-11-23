#!/usr/bin/env bash
# Smoke test of the built host stack (S1). No Windows needed.
#
# Boots a disk-less VM into UEFI firmware with the production GPU device
# (virtio-ramfb-gl + venus + neptune), swtpm as TPM 2.0, and QMP. Checks over
# QMP that the VM runs and the devices exist, then shuts everything down.
#
# Usage: scripts/smoke-qemu.sh [--seconds N] [--window]
#   --window   use -display cocoa,gl=es with the GL GPU device (opens a
#              window for the duration). The default is headless.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$ROOT/build/prefix"
QEMU="$PREFIX/bin/qemu-system-aarch64"
SWTPM="$PREFIX/bin/swtpm"
SECONDS_TO_RUN=8
DISPLAY_ARG="none"
while (( $# )); do
  case "$1" in
    --seconds) SECONDS_TO_RUN="$2"; shift 2 ;;
    --window)  DISPLAY_ARG="cocoa,gl=es"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

[[ -x "$QEMU" && -x "$SWTPM" ]] || { echo "build first: scripts/build-deps.sh all" >&2; exit 1; }

# Short socket paths (sun_path limit, docs/02).
RUN="$(mktemp -d /tmp/seemless-smoke.XXXXXX)"
QEMU_PID=""; TPM_PID=""
cleanup() {
  [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true
  [[ -n "$TPM_PID"  ]] && kill "$TPM_PID"  2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT

mkdir -p "$RUN/tpm"
# aarch64 edk2 needs a 64 MiB variable store; QEMU ships no aarch64 vars
# template (edk2-arm-vars.fd is for 32-bit ARM), so start from zeros.
mkfile -n 64m "$RUN/vars.fd"

"$SWTPM" socket --tpm2 --tpmstate dir="$RUN/tpm" \
  --ctrl type=unixio,path="$RUN/swtpm.sock" --log file="$RUN/swtpm.log",level=5 &
TPM_PID=$!
for _ in $(seq 50); do [[ -S "$RUN/swtpm.sock" ]] && break; sleep 0.1; done

export ANGLE_DEFAULT_PLATFORM=metal
export DYLD_FALLBACK_LIBRARY_PATH="$PREFIX/lib:$PREFIX/ANGLE.xcarchive/Products/usr/local/lib"

GPU="virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2"
if [[ "$DISPLAY_ARG" == none ]]; then
  # virtio-gpu-gl refuses to start without a GL-capable display, so the
  # headless run uses the plain device and only the windowed run tests GL.
  GPU="virtio-ramfb,max_outputs=2"
fi

"$QEMU" -name seemless-smoke -nodefaults -no-user-config \
  -machine virt,highmem=on -accel hvf,ipa-granule-size=0x1000 -cpu host \
  -smp 2 -m 2048 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$PREFIX/share/qemu/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,unit=1,file="$RUN/vars.fd" \
  -device "$GPU" -display "$DISPLAY_ARG" \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -device virtio-serial-pci \
  -chardev socket,id=tpm,path="$RUN/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=tpm -device tpm-tis-device,tpmdev=tpm0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -qmp unix:"$RUN/qmp.sock",server=on,wait=off \
  -serial file:"$RUN/serial.log" \
  >"$RUN/qemu.log" 2>&1 &
QEMU_PID=$!

for _ in $(seq 100); do [[ -S "$RUN/qmp.sock" ]] && break; sleep 0.1; done
[[ -S "$RUN/qmp.sock" ]] || { echo "QEMU did not start:"; cat "$RUN/qemu.log"; exit 1; }

show_logs() {
  echo "--- qemu stderr"; cat "$RUN/qemu.log"
  echo "--- firmware serial (last lines)"; tail -5 "$RUN/serial.log" 2>/dev/null | tr -d '\r' || true
}

sleep "$SECONDS_TO_RUN"
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  st=0; wait "$QEMU_PID" || st=$?; echo "QEMU exited early (status $st)"; QEMU_PID=""; show_logs; exit 1
fi

# Ask QMP for status and devices, then quit.
set +e
python3 -I - "$RUN/qmp.sock" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
def cmd(name, **args):
    f.write(json.dumps({"execute": name, **({"arguments": args} if args else {})}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
json.loads(f.readline())                     # greeting
cmd("qmp_capabilities")
st = cmd("query-status")["return"]
print("status:", st["status"], "running" if st["running"] else "NOT running")
tpm = cmd("query-tpm")["return"]
print("tpm:", [(t["model"], t["options"]["type"]) for t in tpm])
pci = cmd("query-pci")["return"]
names = sorted({d.get("qdev_id") or d["class_info"].get("desc", "?") for b in pci for d in b["devices"]})
print("pci:", ", ".join(names))
ok = st["running"] and tpm
cmd("quit")
sys.exit(0 if ok else 1)
PY
rc=$?
wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
show_logs
exit $rc
