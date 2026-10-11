#!/bin/sh
# Tunnel mode: Klipper, Moonraker and Mainsail run on a separate SBC
# (see opencreator-tunnel); the printer's own board keeps only the
# serial bridge. opencreator-fs already ships the bridge loop at
# /usr/data/opencreator/tunneled/tunneled.sh -- installing this mode
# means staging c5_bridge.py where that script expects it
# (/usr/prog/c5-tunnel/c5_bridge.py, which self-builds its native
# urb_reader helper on first run) and swapping it in for 10-klipper.sh
# so startup.sh launches the bridge instead of klippy.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}

BRIDGE_DIR="$DEMO_ROOT/usr/prog/c5-tunnel"
BRIDGE_SRC="$OC_PAYLOAD/tunnel/c5_bridge.py"
LAUNCHER="$DEMO_ROOT/usr/data/opencreator/startup/scripts/10-klipper.sh"
LAUNCHER_BACKUP="$DEMO_ROOT/usr/data/opencreator/startup/scripts/10-klipper.sh.soc-backup"
TUNNELED_SCRIPT="$DEMO_ROOT/usr/data/opencreator/tunneled/tunneled.sh"

die() { echo "ERROR $*"; exit 1; }

if [ -n "$DEMO_ROOT" ] && { [ ! -f "$TUNNELED_SCRIPT" ] || [ ! -f "$LAUNCHER" ]; }; then
    echo "STAGE Demo mode: synthesizing the rootfs-baked tunnel launcher" \
         "this step normally just verifies is already present"
    mkdir -p "$(dirname "$TUNNELED_SCRIPT")" "$(dirname "$LAUNCHER")"
    [ -f "$TUNNELED_SCRIPT" ] || printf '#!/bin/sh\nexec /usr/prog/c5-tunnel/c5_bridge.py\n' > "$TUNNELED_SCRIPT"
    [ -f "$LAUNCHER" ] || printf '#!/bin/sh\nexec klippy.py\n' > "$LAUNCHER"
fi

[ -f "$BRIDGE_SRC" ] || die "missing bridge payload: $BRIDGE_SRC (stage opencreator-tunnel's printer/c5_bridge.py there)"
[ -f "$TUNNELED_SCRIPT" ] || die "$TUNNELED_SCRIPT not found; the rootfs does not ship the tunnel launcher"

echo "STAGE Installing the Creator 5 tunnel bridge"
mkdir -p "$BRIDGE_DIR"
cp "$BRIDGE_SRC" "$BRIDGE_DIR/c5_bridge.py"
chmod 755 "$BRIDGE_DIR/c5_bridge.py"

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: skipping the real urb_reader build" \
         "(needs the printer's own Python-3.8.2/gcc toolchain, not" \
         "present off-device) -- would run:" \
         "LD_LIBRARY_PATH=.../usr/prog/Python-3.8.2/lib:... PYTHONPATH=$BRIDGE_DIR" \
         "/usr/prog/Python-3.8.2/bin/python3 -c" \
         "'import c5_bridge; c5_bridge.ensure_urb_reader_binary()'"
else
    export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:/usr/prog/openssl-1.0.2d/lib:/usr/prog/libffi-3.4.4/lib:${LD_LIBRARY_PATH:-}
    export PYTHONPATH="$BRIDGE_DIR"${PYTHONPATH:+:$PYTHONPATH}
    /usr/prog/Python-3.8.2/bin/python3 -c \
        'import c5_bridge, sys; sys.exit(0 if c5_bridge.ensure_urb_reader_binary() else 1)' \
        || die "could not build the USB URB reader; check /opt/bin/gcc and /opt/include"
fi

if [ ! -f "$LAUNCHER_BACKUP" ]; then
    echo "STAGE Backing up the Klipper launcher"
    cp -p "$LAUNCHER" "$LAUNCHER_BACKUP"
fi

echo "STAGE Switching the printer board to bridge-only mode"
cp -p "$TUNNELED_SCRIPT" "$LAUNCHER"
chmod 755 "$LAUNCHER"

echo "STAGE Tunnel bridge installed; reboot the printer, then install" \
     "Klipper/Moonraker/Mainsail on the SBC per opencreator-tunnel's README"
