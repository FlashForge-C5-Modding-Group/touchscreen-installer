#!/bin/sh
# Last step: switch the printer to LoopScript (opencreator-fs firmwareExe)
# and the OpenCreator boot logo. Earlier failures leave the stock ones.
set -eu
DEMO_ROOT=${OC_DEMO_ROOT:-}
OCDIR=$DEMO_ROOT/usr/data/opencreator
FIRMWARE_EXE=$DEMO_ROOT/usr/prog/PROGRAM/software/firmwareExe
LOGO=$DEMO_ROOT/usr/prog/logo.jpeg
: "${OC_PAYLOAD:?}"

die() { echo "ERROR $*"; exit 1; }

[ -f "$OCDIR/firmware/firmwareExe" ] || die "LoopScript is not installed"

# OpenCreator Legacy's guide adds start lines to app_startup.sh: its
# LoopScript, and its webcam followed by "sleep 2". That script also runs the USB update check, so a broken
# copy bricks the printer: the line is replaced by a no-op (keeping every
# block valid), and the result is checked before it replaces the original.
# Also check on updates: recovery may have restored the original legacy entry.
# Already-sanitized startup scripts are left unchanged.
APP_STARTUP=$DEMO_ROOT/usr/prog/app_startup.sh
LEGACY_RE='^[[:space:]]*(sh[[:space:]]+)?/usr/prog/scripts/loop/loop\.sh[[:space:]]*&?[[:space:]]*$'
WEBCAM_RE='^[[:space:]]*(sh[[:space:]]*)?/usr/prog/mjpg-streamer/start_webcam\.sh[[:space:]]*&?[[:space:]]*$'
SLEEP_RE='^[[:space:]]*sleep[[:space:]]+2[[:space:]]*;?[[:space:]]*$'
MARK_RE='^: # OpenCreator: Legacy (LoopScript|webcam start) disabled'
# legacy_lines count|disable|drop FILE: the legacy LoopScript line and the
# webcam start line followed by "sleep 2", counted, swapped for no-ops, or left out.
legacy_lines() {
    LRE=$LEGACY_RE WRE=$WEBCAM_RE SRE=$SLEEP_RE awk -v mode="$1" '
        BEGIN { lre = ENVIRON["LRE"]; wre = ENVIRON["WRE"]; sre = ENVIRON["SRE"] }
        function keep(s) { if (mode != "count") print s }
        function off(s) { n++; if (mode == "disable") print s }
        {
            if (held) {
                held = 0
                if ($0 ~ sre) {
                    off(": # OpenCreator: Legacy webcam start disabled (was " t ")")
                    off(": # OpenCreator: Legacy webcam start disabled (was sleep 2)")
                    next
                }
                keep(w)
            }
            if ($0 ~ lre) { off(": # OpenCreator: Legacy LoopScript disabled (was /usr/prog/scripts/loop/loop.sh &)"); next }
            if ($0 ~ wre) { held = 1; w = $0; t = $0; sub(/^[[:space:]]+/, "", t); next }
            keep($0)
        }
        END { if (held) keep(w); if (mode == "count") print n + 0 }' "$2"
}
# Activation is preparing the current launcher, even before its first install.
/bin/sh "$OC_PAYLOAD/common/recover-app-startup.sh" opencreator ||
    die "could not recover app_startup.sh before activation"
matches=0
[ ! -f "$APP_STARTUP" ] || matches=$(legacy_lines count "$APP_STARTUP") ||
    die "cannot inspect app_startup.sh"
if [ "$matches" -gt 0 ]; then
    echo "STAGE Disabling the OpenCreator Legacy start lines"
    [ -f "$APP_STARTUP.opencreator-legacy" ] || cp -p "$APP_STARTUP" "$APP_STARTUP.opencreator-legacy"
    new=$APP_STARTUP.opencreator-new
    cleanup_and_recover() {
        rm -f "$new" "$new.after" "$new.orig" ||
            echo "WARN could not remove temporary startup files"
        /bin/sh "$OC_PAYLOAD/common/recover-app-startup.sh" ||
            echo "ERROR could not recover app_startup.sh during activation cleanup"
    }
    trap cleanup_and_recover EXIT
    rm -f "$new"
    cp -p "$APP_STARTUP" "$new"
    legacy_lines disable "$APP_STARTUP" > "$new" || { rm -f "$new"; die "could not edit app_startup.sh"; }
    # Every other line must be unchanged, byte for byte.
    grep -Ev "$MARK_RE" "$new" > "$new.after" || true
    legacy_lines drop "$APP_STARTUP" | grep -Ev "$MARK_RE" > "$new.orig" || true
    added=$(( $(grep -Ec "$MARK_RE" "$new" || true) - $(grep -Ec "$MARK_RE" "$APP_STARTUP" || true) ))
    if [ "$(awk 'END { print NR }' "$new")" -ne "$(awk 'END { print NR }' "$APP_STARTUP")" ] ||
        [ "$added" -ne "$matches" ] ||
        [ "$(md5sum < "$new.after")" != "$(md5sum < "$new.orig")" ] ||
        [ "$(legacy_lines count "$new")" -ne 0 ] ||
        ! sh -n "$new" ||
        ! grep -q 'runFirmwareExe.sh' "$new" ||
        ! grep -q 'PROGRAM/software/firmwareExe' "$new"; then
        rm -f "$new" "$new.after" "$new.orig"
        die "edited app_startup.sh failed its checks; left unchanged"
    fi
    rm -f "$new.after" "$new.orig"
    sync
    mv "$new" "$APP_STARTUP"
    chmod 777 "$APP_STARTUP"
    sync
    if [ ! -x "$APP_STARTUP" ] || ! sh -n "$APP_STARTUP"; then
        echo "ERROR app_startup.sh failed post-swap checks; restoring legacy backup"
        /bin/sh "$OC_PAYLOAD/common/recover-app-startup.sh" auto replace ||
            die "app_startup.sh check failed and legacy recovery failed"
        die "app_startup.sh check failed after the swap; restored original"
    fi
    trap - EXIT
fi

if [ -f "$LOGO" ] && [ ! -f "$OCDIR/logo.jpeg.stock" ]; then
    cp -p "$LOGO" "$OCDIR/logo.jpeg.stock"
fi
# A logo that is neither stock nor the one installed last time is the user's.
if [ -f "$LOGO" ] && [ -f "$OCDIR/logo.jpeg.installed" ] &&
    ! cmp -s "$LOGO" "$OCDIR/logo.jpeg.installed" && ! cmp -s "$LOGO" "$OCDIR/logo.jpeg.stock"; then
    echo "STAGE Keeping your custom boot logo"
else
    echo "STAGE Installing the OpenCreator boot logo"
    cp "$OC_PAYLOAD/common/logo.jpeg" "$LOGO"
    cp "$OC_PAYLOAD/common/logo.jpeg" "$OCDIR/logo.jpeg.installed"
fi

echo "STAGE Replacing firmwareExe with the LoopScript launcher"
mkdir -p "$(dirname "$FIRMWARE_EXE")"
if [ -f "$FIRMWARE_EXE" ] && [ ! -f "$OCDIR/firmwareExe.stock" ]; then
    magic=$(dd if="$FIRMWARE_EXE" bs=1 skip=1 count=3 2>/dev/null)
    if [ "$magic" = ELF ]; then
        cp -p "$FIRMWARE_EXE" "$OCDIR/firmwareExe.stock"
    fi
fi
cp "$OCDIR/firmware/firmwareExe" "$FIRMWARE_EXE.new"
chmod 755 "$FIRMWARE_EXE.new"
mv "$FIRMWARE_EXE.new" "$FIRMWARE_EXE"
sync
echo "STAGE LoopScript active"

# Recover with the current launcher selected if a later operation lost startup.
/bin/sh "$OC_PAYLOAD/common/recover-app-startup.sh" opencreator ||
    die "could not recover app_startup.sh after activation"
[ -f "$APP_STARTUP" ] || die "critical boot script missing: $APP_STARTUP"
[ -x "$APP_STARTUP" ] || chmod 777 "$APP_STARTUP"
