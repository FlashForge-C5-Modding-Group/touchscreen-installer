#!/bin/sh
# Printer SoC mode: moonraker-timelapse. The Moonraker component and the
# Klipper macros are linked from a clone that Moonraker's update manager
# keeps current; ffmpeg comes from the printer (Entware if missing).
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

TIMELAPSE_REPO=${TIMELAPSE_REPO:-https://github.com/mainsail-crew/moonraker-timelapse.git}
TL=$DEMO_ROOT/usr/data/opencreator/moonraker-timelapse
MR=$DEMO_ROOT/usr/prog/moonraker
CONFIG=$DEMO_ROOT/usr/data/opencreator/klipper/config
MOONRAKER_CONF=$CONFIG/moonraker.conf
OUT=/usr/data/opencreator/timelapse

die() { echo "ERROR $*"; exit 1; }

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would clone $TIMELAPSE_REPO to $TL"
    mkdir -p "$TL/component" "$TL/klipper_macro"
    : > "$TL/component/timelapse.py"
    : > "$TL/klipper_macro/timelapse.cfg"
elif [ -d "$TL/.git" ]; then
    echo "STAGE Updating moonraker-timelapse"
    git -C "$TL" fetch --depth 1 origin HEAD || die "cannot download moonraker-timelapse"
    git -C "$TL" reset -q --hard FETCH_HEAD || die "cannot update moonraker-timelapse"
else
    oc_git_clone_shallow "$TIMELAPSE_REPO" "$TL" || die "cannot download moonraker-timelapse"
fi

[ -d "$MR/moonraker/moonraker/components" ] || die "Moonraker is not installed"
ln -sf "$TL/component/timelapse.py" "$MR/moonraker/moonraker/components/timelapse.py"
mkdir -p "$CONFIG"
ln -sf "$TL/klipper_macro/timelapse.cfg" "$CONFIG/timelapse.cfg"
mkdir -p "$DEMO_ROOT$OUT/frames"

# FlashForge's ffmpeg (with libx264) needs its library folders; renders run
# at the lowest priority so they never hold up Klipper.
FF=/usr/prog/ffmpeg-402
FFMPEG=$DEMO_ROOT$OUT/ffmpeg
if [ -z "$DEMO_ROOT" ] && [ ! -x "$FF/bin/ffmpeg" ] && [ ! -x /opt/bin/ffmpeg ]; then
    echo "STAGE Installing ffmpeg (this takes a while)"
    oc_run_staged /opt/bin/opkg install ffmpeg || die "cannot install ffmpeg"
fi
if [ -n "$DEMO_ROOT" ] || [ -x "$FF/bin/ffmpeg" ]; then
    printf '#!/bin/sh\nLD_LIBRARY_PATH=%s/lib:/usr/prog/x264/lib exec nice -n 19 %s/bin/ffmpeg "$@"\n' \
        "$FF" "$FF" > "$FFMPEG"
else
    printf '#!/bin/sh\nexec nice -n 19 /opt/bin/ffmpeg "$@"\n' > "$FFMPEG"
fi
chmod 755 "$FFMPEG"

# The include goes first: the end of printer.cfg is Klipper's SAVE_CONFIG
# block. A kept printer.cfg lacks it, or has it lower down.
PRINTER_CFG=$CONFIG/printer.cfg
if [ -f "$PRINTER_CFG" ] && [ "$(head -n 1 "$PRINTER_CFG")" != '[include timelapse*.cfg]' ]; then
    echo "STAGE Adding the timelapse macros to the top of printer.cfg"
    { echo '[include timelapse*.cfg]'; grep -v '^\[include timelapse\*\.cfg\]$' "$PRINTER_CFG"; } \
        > "$PRINTER_CFG.new" && mv "$PRINTER_CFG.new" "$PRINTER_CFG"
fi

if [ -f "$MOONRAKER_CONF" ]; then
    if ! grep -q '^\[timelapse\]' "$MOONRAKER_CONF"; then
        echo "STAGE Adding timelapse to moonraker.conf"
        # Frames go to /usr/data, not /tmp: /tmp is RAM.
        printf '\n[timelapse]\noutput_path: %s/\nframe_path: %s/frames/\nffmpeg_binary_path: %s/ffmpeg\nsnapshoturl: http://localhost:8080/?action=snapshot\n' \
            "$OUT" "$OUT" "$OUT" >> "$MOONRAKER_CONF"
    fi
    if ! grep -q '^\[update_manager timelapse\]' "$MOONRAKER_CONF"; then
        printf '\n[update_manager timelapse]\ntype: git_repo\nprimary_branch: main\npath: /usr/data/opencreator/moonraker-timelapse\norigin: %s\nmanaged_services: klipper moonraker\n' \
            "$TIMELAPSE_REPO" >> "$MOONRAKER_CONF"
    fi
fi
sync
echo "STAGE Timelapse installed"
