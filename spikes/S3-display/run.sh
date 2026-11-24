#!/bin/bash
# Spike S3: start the patched QEMU (build/s3) with -display seemless or cocoa.
#
#   run.sh seemless|cocoa <workdir> [disk.qcow2 [efi_vars.fd [tpm_state_dir]]]
#
# Without a disk the guest stays in firmware (enough to prove the display path).
# The QMP socket is <workdir>/qmp.sock; the Mach service is app.seemless.s3.<basename workdir>.
# Leaves QEMU running in the foreground; its log goes to <workdir>/qemu.log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU="$ROOT/build/s3/qemu/build/qemu-system-aarch64"
SHARE="$ROOT/build/prefix/share/qemu"
mode="$1"; work="$2"; disk="${3:-}"; vars="${4:-}"; tpm="${5:-}"
mkdir -p "$work"
if [[ -z "$vars" ]]; then
  vars="$work/efi_vars.fd"
  [[ -f "$vars" ]] || mkfile -n 64m "$vars"
fi
case "$mode" in
  seemless) display=(-display "seemless,gl=es,service=app.seemless.s3.$(basename "$work")") ;;
  cocoa)    display=(-display cocoa,gl=es) ;;
  *) echo "mode: seemless|cocoa" >&2; exit 2 ;;
esac
args=(
  -name "s3-$mode" -nodefaults -no-user-config
  -machine virt,highmem=on -accel hvf,ipa-granule-size=0x1000 -cpu host
  -smp 4 -m 8192
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$SHARE/edk2-aarch64-code.fd"
  -drive "if=pflash,format=raw,unit=1,file=$vars"
  -device virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,max_outputs=2
  "${display[@]}"
  -device qemu-xhci,id=usb -device usb-kbd -device usb-tablet
  -qmp "unix:$work/qmp.sock,server=on,wait=off"
  -qmp "unix:$work/qmp2.sock,server=on,wait=off"   # second client (latency tool)
)
if [[ -n "$disk" ]]; then
  args+=(-drive "if=none,id=sys,file=$disk,format=qcow2" -device nvme,drive=sys,serial=seemless0,bootindex=1)
fi
if [[ -n "$tpm" ]]; then
  "$ROOT/build/prefix/bin/swtpm" socket --tpm2 --tpmstate "dir=$tpm" \
    --ctrl "type=unixio,path=$work/tpm.sock" --daemon --terminate
  sleep 0.3
  args+=(-chardev "socket,id=tpm,path=$work/tpm.sock" -tpmdev emulator,id=tpm0,chardev=tpm -device tpm-tis-device,tpmdev=tpm0)
fi
rm -f "$work/qmp.sock" "$work/qmp2.sock"
export ANGLE_DEFAULT_PLATFORM=metal NPT_BACKEND=dxmt
export DYLD_FALLBACK_LIBRARY_PATH="$ROOT/build/prefix/lib:$ROOT/build/prefix/ANGLE.xcarchive/Products/usr/local/lib"
exec "$QEMU" "${args[@]}" > "$work/qemu.log" 2>&1
