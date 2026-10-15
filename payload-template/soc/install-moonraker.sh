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

# A previous run that was interrupted (power loss) left the original aside.
for dir in moonraker moonraker-env; do
    if [ -d "$MR/$dir.old" ]; then
        echo "STAGE Putting back $dir from an interrupted install"
        rm -rf "$MR/$dir"
        mv "$MR/$dir.old" "$MR/$dir"
    fi
done
rm -rf "$MR/moonraker.new"

echo "STAGE Downloading Moonraker"
oc_git_clone_shallow "$MOONRAKER_REPO" "$MR/moonraker.new" || die "cannot download Moonraker"

# The current Moonraker and its environment are moved aside and put back if
# anything below fails.
rm -rf "$MR/moonraker.old" "$MR/moonraker-env.old"
[ ! -d "$MR/moonraker" ] || mv "$MR/moonraker" "$MR/moonraker.old"
[ ! -d "$MR/moonraker-env" ] || mv "$MR/moonraker-env" "$MR/moonraker-env.old"
mv "$MR/moonraker.new" "$MR/moonraker"
rollback() {
    for dir in moonraker moonraker-env; do
        if [ -d "$MR/$dir.old" ]; then
            rm -rf "$MR/$dir"
            mv "$MR/$dir.old" "$MR/$dir"
        fi
    done
}
trap 'rc=$?; oc_swap_off; [ $rc -eq 0 ] || rollback' EXIT

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would create $MR/moonraker-env with" \
         "/opt/bin/python3 -m virtualenv --system-site-packages and install" \
         "scripts/moonraker-requirements.txt and lmdb"
else
    echo "STAGE Creating Moonraker's Python environment"
    /opt/bin/python3 -m virtualenv --system-site-packages -p /opt/bin/python3 "$MR/moonraker-env" \
        || die "cannot create $MR/moonraker-env"
    echo "STAGE Installing Moonraker's Python packages (this takes a while)"
    oc_swap_on
    oc_run_staged env SKIP_CYTHON=1 "$MR/moonraker-env/bin/python" -m pip install -r "$MR/moonraker/scripts/moonraker-requirements.txt" \
        || die "Moonraker requirements failed"
    oc_run_staged env SKIP_CYTHON=1 LMDB_FORCE_SYSTEM=1 "$MR/moonraker-env/bin/python" -m pip install --no-build-isolation lmdb \
        || echo "STAGE lmdb not installed (only needed to migrate an old Moonraker database)"
    "$MR/moonraker-env/bin/python" -c 'import tornado, sqlite3, jinja2' \
        || die "Moonraker's environment is incomplete"
    git -C "$MR/moonraker" config core.fileMode false
fi
rm -rf "$MR/moonraker.old" "$MR/moonraker-env.old"
trap - EXIT
oc_swap_off
sync
echo "STAGE Moonraker installed"
