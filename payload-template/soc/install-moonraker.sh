#!/bin/sh
# Printer SoC mode: current Moonraker in /usr/prog/moonraker/moonraker with
# a virtualenv on Entware's Python (Creator-5-Mods "Update Moonraker").
# LoopScript's 20-msmr.sh starts it with -d /usr/data/opencreator/klipper.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

MR=$DEMO_ROOT/usr/prog/moonraker
MOONRAKER_REPO=https://github.com/Arksine/moonraker.git

die() { echo "ERROR $*"; exit 1; }

if [ -z "$DEMO_ROOT" ] && [ -x /usr/prog/klipper/moonrakerDaemon ]; then
    echo "STAGE Stopping the stock Moonraker"
    /usr/prog/klipper/moonrakerDaemon stop >/dev/null 2>&1 || true
fi

echo "STAGE Installing Moonraker to $MR/moonraker"
oc_git_clone_shallow "$MOONRAKER_REPO" "$MR/moonraker" || die "cannot download Moonraker"

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would create $MR/moonraker-env with" \
         "/opt/bin/python3 -m virtualenv --system-site-packages and install" \
         "scripts/moonraker-requirements.txt and lmdb"
else
    echo "STAGE Creating Moonraker's Python environment"
    rm -rf "$MR/moonraker-env"
    /opt/bin/python3 -m virtualenv --system-site-packages -p /opt/bin/python3 "$MR/moonraker-env" \
        || die "cannot create $MR/moonraker-env"
    echo "STAGE Installing Moonraker's Python packages (this takes a while)"
    "$MR/moonraker-env/bin/pip" install -r "$MR/moonraker/scripts/moonraker-requirements.txt" \
        || die "Moonraker requirements failed"
    LMDB_FORCE_SYSTEM=1 "$MR/moonraker-env/bin/pip" install --no-build-isolation lmdb \
        || echo "STAGE lmdb not installed (only needed to migrate an old Moonraker database)"
    git -C "$MR/moonraker" config core.fileMode false
fi
sync
echo "STAGE Moonraker installed"
