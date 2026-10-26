#!/bin/sh
# Tunnel mode: the socat MCU bridge (opencreator-tunnel/printer-socat) in
# /usr/prog/c5-tunnel-socat, started by LoopScript's tunneled/tunneled.sh.
# Klipper, Moonraker and the web UI run on the SBC.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

TUNNEL_REPO=${OC_TUNNEL_REPO:-https://github.com/FlashForge-C5-Modding-Group/opencreator-tunnel.git}
BRIDGE_DIR=$DEMO_ROOT/usr/prog/c5-tunnel-socat
TUNNELED_SCRIPT=$DEMO_ROOT/usr/data/opencreator/tunneled/tunneled.sh

die() { echo "ERROR $*"; exit 1; }

[ -f "$TUNNELED_SCRIPT" ] || die "$TUNNELED_SCRIPT missing; LoopScript is not installed"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-tunnel.XXXXXX") || die "cannot create work directory"
trap 'rm -rf "$WORK"' EXIT
oc_git_clone_shallow "$TUNNEL_REPO" "$WORK/opencreator-tunnel" \
    || die "cannot download opencreator-tunnel"
SRC=$WORK/opencreator-tunnel/printer-socat
[ -f "$SRC/c5_socat.py" ] && [ -f "$SRC/identify_monitor.c" ] || die "printer-socat incomplete"

echo "STAGE Installing the socat bridge to $BRIDGE_DIR"
mkdir -p "$BRIDGE_DIR"
cp "$SRC/c5_socat.py" "$SRC/identify_monitor.c" "$SRC/README.md" "$BRIDGE_DIR/"
chmod 755 "$BRIDGE_DIR/c5_socat.py"
# usb-serial modules for FlashForge kernel 2.0.8, which has none. Skip them
# when usb-serial is built in (/sys/bus/usb-serial exists but usbserial isn't
# a loadable module); a loaded usbserial module is ours from an earlier
# install, so keep copying in that case.
rm -rf "$BRIDGE_DIR/modules"
if [ -d /sys/bus/usb-serial ] && ! grep -q '^usbserial ' /proc/modules 2>/dev/null; then
    echo "STAGE usb-serial is built into this kernel; skipping the bundled modules"
elif [ -d "$SRC/modules" ]; then
    echo "STAGE Installing usb-serial modules (this kernel has no usb-serial)"
    cp -r "$SRC/modules" "$BRIDGE_DIR/modules"
fi

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would build identify_monitor with /opt/bin/gcc and" \
         "check c5_socat.py with the printer's Python 3.8"
else
    [ -x /opt/bin/socat ] || die "Entware socat missing"
    export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:/usr/prog/openssl-1.0.2d/lib:/usr/prog/libffi-3.4.4/lib:${LD_LIBRARY_PATH:-}
    /usr/prog/Python-3.8.2/bin/python3 -m py_compile "$BRIDGE_DIR/c5_socat.py" \
        || die "c5_socat.py syntax check failed"
    echo "STAGE Building identify_monitor"
    /opt/bin/gcc -std=c99 -O2 -Wall -Wextra -Werror \
        -o "$BRIDGE_DIR/identify_monitor.new" "$BRIDGE_DIR/identify_monitor.c" \
        || die "identify_monitor build failed"
    chmod 755 "$BRIDGE_DIR/identify_monitor.new"
    mv -f "$BRIDGE_DIR/identify_monitor.new" "$BRIDGE_DIR/identify_monitor"
fi

echo "STAGE Switching the printer board to bridge-only mode"
chmod 755 "$TUNNELED_SCRIPT"
sync
echo "STAGE Socat bridge installed; reboot the printer, then install" \
     "Klipper/Moonraker/Fluidd on the SBC per opencreator-tunnel's README"
