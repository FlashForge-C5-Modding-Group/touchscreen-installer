#!/bin/sh
# Turn on printer.dryer.cfg only when a FlashForge VDS dryer answers on /dev/ttyS3.
set -eu
DEMO_ROOT=${OC_DEMO_ROOT:-}
CONFIG=$DEMO_ROOT/usr/data/opencreator/klipper/config
ENABLE=$CONFIG/printer.accessory.dryer.cfg
PORT=/dev/ttyS3

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo: skipping the filament dryer check"
    exit 0
fi

reply=
if [ -c "$PORT" ] && stty -F "$PORT" 115200 raw -echo 2>/dev/null; then
    out=$(mktemp)
    for try in 1 2; do
        cat "$PORT" > "$out" 2>/dev/null &
        reader=$!
        sleep 1
        printf 'M16\n' > "$PORT"
        sleep 2
        kill "$reader" 2>/dev/null || true
        wait "$reader" 2>/dev/null || true
        reply=$(tr -d '\r' < "$out" | grep -E 'M16 ok\.|Boot' | head -n 1) || reply=
        [ -z "$reply" ] || break
    done
    rm -f "$out"
fi

if [ -n "$reply" ]; then
    mkdir -p "$CONFIG"
    printf '# Written by the installer: a VDS filament dryer answered on %s\n[include printer.dryer.cfg]\n' "$PORT" > "$ENABLE"
    echo "STAGE Filament dryer found (${reply#M16 ok. }); dryer controls turned on"
elif [ -f "$ENABLE" ]; then
    echo "STAGE No filament dryer answered; keeping the dryer controls that were already on"
else
    echo "STAGE No filament dryer found; dryer controls left off"
fi
