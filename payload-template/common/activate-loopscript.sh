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

# OpenCreator Legacy's LoopScript is started by a line its guide adds to
# app_startup.sh. That script also runs the USB update check, so a broken
# copy bricks the printer: the line is replaced by a no-op (keeping every
# block valid), and the result is checked before it replaces the original.
# Only on a new install: an update (OC_UPDATE=1) never reads or changes
# app_startup.sh, which the first install already handled.
APP_STARTUP=$DEMO_ROOT/usr/prog/app_startup.sh
LEGACY_RE='^[[:space:]]*(sh[[:space:]]+)?/usr/prog/scripts/loop/loop\.sh[[:space:]]*&?[[:space:]]*$'
if [ "${OC_UPDATE:-0}" != 1 ] && [ -f "$APP_STARTUP" ] && grep -Eq "$LEGACY_RE" "$APP_STARTUP"; then
    echo "STAGE Disabling the OpenCreator Legacy LoopScript start line"
    matches=$(grep -Ec "$LEGACY_RE" "$APP_STARTUP" || true)
    [ -f "$APP_STARTUP.opencreator-legacy" ] || cp -p "$APP_STARTUP" "$APP_STARTUP.opencreator-legacy"
    new=$APP_STARTUP.opencreator-new
    trap 'rm -f "$new" "$new.after" "$new.orig"' EXIT
    rm -f "$new"
    cp -p "$APP_STARTUP" "$new"
    marker=': # OpenCreator: Legacy LoopScript disabled'
    sed -E "s|$LEGACY_RE|$marker (was /usr/prog/scripts/loop/loop.sh \\&)|" \
        "$APP_STARTUP" > "$new" || { rm -f "$new"; die "could not edit app_startup.sh"; }
    # Every other line must be unchanged, byte for byte.
    grep -Fv "$marker" "$new" > "$new.after" || true
    grep -Fv "$marker" "$APP_STARTUP" | grep -Ev "$LEGACY_RE" > "$new.orig" || true
    added=$(( $(grep -Fc "$marker" "$new" || true) - $(grep -Fc "$marker" "$APP_STARTUP" || true) ))
    if [ "$(wc -l < "$new")" -ne "$(wc -l < "$APP_STARTUP")" ] ||
        [ "$added" -ne "$matches" ] ||
        [ "$(md5sum < "$new.after")" != "$(md5sum < "$new.orig")" ] ||
        grep -Eq "$LEGACY_RE" "$new" ||
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
    [ -x "$APP_STARTUP" ] || die "app_startup.sh is not executable after the swap"
    sh -n "$APP_STARTUP" || die "app_startup.sh check failed after the swap"
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
