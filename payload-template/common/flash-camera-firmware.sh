#!/bin/sh
# Update the printer camera (Sunplus, USB 05a3:9230) to FlashForge's camera
# firmware 1226 from the 2.0.0 update, which FlashForge ships but doesn't flash
# yet. Only the image tuning tables and the USB maker name differ from 1224;
# the code is the same. Shared by both install modes. A camera problem is a
# warning: the install carries on.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}

FW_DIR=$OC_PAYLOAD/camera-firmware
WANT=1226
LOG=$DEMO_ROOT/usr/data/logs/oc-camera-firmware.log

warn() { echo "WARN Camera firmware not updated: $*"; exit 0; }

camera_version() {
    for d in "$DEMO_ROOT"/sys/bus/usb/devices/*; do
        [ "$(cat "$d/idVendor" 2>/dev/null)" = 05a3 ] &&
            [ "$(cat "$d/idProduct" 2>/dev/null)" = 9230 ] &&
            { cat "$d/bcdDevice"; return 0; }
    done
    return 1
}

[ -f "$FW_DIR/x$WANT.bin" ] || { echo "STAGE No camera firmware staged, skipping"; exit 0; }
have=$(camera_version) || { echo "STAGE No supported camera found, skipping"; exit 0; }
if [ "$have" -ge "$WANT" ] 2>/dev/null; then
    echo "STAGE Camera already on firmware $have"
    exit 0
fi
(cd "$FW_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || warn "files don't match SHA256SUMS"

# Same lookup as FlashForge's run.sh: the camera's video node by name
index=
for v in "$DEMO_ROOT"/sys/class/video4linux/video*; do
    [ "$(cat "$v/name" 2>/dev/null)" = "Integrated Camera: Integrated C" ] || continue
    index=${v##*video}
    break
done
[ -n "$index" ] || warn "no video device for the camera"

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would flash camera firmware $have -> $WANT on /dev/video$index"
    exit 0
fi

echo "STAGE Updating camera firmware $have -> $WANT"
# Pause whatever restarts the stream and stop it while the camera is flashed
pids_of() {
    for d in /proc/[0-9]*; do
        tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "$1" && echo "${d#/proc/}"
    done
    return 0
}
STREAM=$(pids_of 'mjpg_streamer -i')
LOOPS=
for p in $STREAM; do LOOPS="$LOOPS $(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)"; done
resume() { [ -z "${LOOPS# }" ] || kill -CONT $LOOPS 2>/dev/null || true; }
trap resume EXIT INT TERM HUP
[ -z "${LOOPS# }" ] || kill -STOP $LOOPS 2>/dev/null || true
[ -z "$STREAM" ] || kill $STREAM 2>/dev/null || true
sleep 2

mkdir -p "$(dirname "$LOG")"
# The USB drive may not allow exec, so run the flasher from a copy
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-camera.XXXXXX") || warn "cannot create a work directory"
trap 'resume; rm -rf "$WORK"' EXIT INT TERM HUP
cp "$FW_DIR/V4L2_FWUpdate_mips" "$FW_DIR/x$WANT.bin" "$WORK/" && chmod 755 "$WORK/V4L2_FWUpdate_mips" ||
    warn "cannot copy the flasher"
"$WORK/V4L2_FWUpdate_mips" -D "$index" -d "$WORK/x$WANT.bin" -V "$WANT" > "$LOG" 2>&1 || true
sleep 3
now=$(camera_version) || now=
grep -q "Download finished(0)" "$LOG" && [ "$now" = "$WANT" ] ||
    warn "the flasher didn't finish (camera reports ${now:-nothing}); see $LOG"
echo "STAGE Camera firmware updated to $now"
