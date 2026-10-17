#!/bin/sh
# Printer SoC mode: current Moonraker in /usr/prog/moonraker/moonraker with
# a virtualenv on the hard-float Python in /usr/data/python-hf. pip builds
# its C extensions with python-hf's gcc wrapper, so they are hard-float too.
# LoopScript's 20-msmr.sh starts it with -d /usr/data/opencreator/klipper.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

MR=$DEMO_ROOT/usr/prog/moonraker
PYHF=$DEMO_ROOT/usr/data/python-hf
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

# Arksine's Moonraker is updated in place (untracked files stay) and reset to
# its old commit on failure; anything else (FlashForge's) is moved aside and
# replaced, and put back on failure. A new environment is likewise built
# with the current one moved aside.
OLD_HEAD=
rollback() {
    for dir in moonraker moonraker-env; do
        if [ -d "$MR/$dir.old" ]; then
            rm -rf "$MR/$dir"
            mv "$MR/$dir.old" "$MR/$dir"
        fi
    done
    [ -z "$OLD_HEAD" ] || git -C "$MR/moonraker" reset -q --hard "$OLD_HEAD" || true
}
trap 'rc=$?; oc_swap_off; [ $rc -eq 0 ] || rollback' EXIT
rm -rf "$MR/moonraker.old" "$MR/moonraker-env.old"

if git -C "$MR/moonraker" remote get-url origin 2>/dev/null | grep -q Arksine; then
    echo "STAGE Updating Moonraker in place"
    OLD_HEAD=$(git -C "$MR/moonraker" rev-parse HEAD) || die "cannot read the Moonraker checkout"
    git -C "$MR/moonraker" fetch --depth 1 origin || die "cannot download Moonraker"
    git -C "$MR/moonraker" reset -q --hard FETCH_HEAD || die "cannot update Moonraker"
else
    echo "STAGE Downloading Moonraker"
    oc_git_clone_shallow "$MOONRAKER_REPO" "$MR/moonraker.new" || die "cannot download Moonraker"
    [ ! -d "$MR/moonraker" ] || mv "$MR/moonraker" "$MR/moonraker.old"
    mv "$MR/moonraker.new" "$MR/moonraker"
fi

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would create $MR/moonraker-env with python-hf -m venv" \
         "--system-site-packages and install scripts/moonraker-requirements.txt"
else
    [ -x "$PYHF/bin/python3.13" ] || die "hard-float Python is not installed"
    if grep -qx "home = /usr/data/python-hf/bin" "$MR/moonraker-env/pyvenv.cfg" 2>/dev/null; then
        echo "STAGE Moonraker's Python environment is on hard-float Python"
    else
        echo "STAGE Creating Moonraker's Python environment"
        [ ! -d "$MR/moonraker-env" ] || mv "$MR/moonraker-env" "$MR/moonraker-env.old"
        "$PYHF/bin/python3.13" -m venv --system-site-packages "$MR/moonraker-env" \
            || die "cannot create $MR/moonraker-env"
    fi
    echo "STAGE Installing Moonraker's Python packages (this takes a while)"
    oc_swap_on
    # SKIP_CYTHON: zeroconf as plain Python, not compiled. Pillow looks for
    # zlib and libjpeg in CFLAGS/LDFLAGS, not in the gcc wrapper's paths.
    oc_run_staged env SKIP_CYTHON=1 CFLAGS="-I$PYHF/include" LDFLAGS="-L$PYHF/lib" \
        "$MR/moonraker-env/bin/python" -m pip install \
        --disable-pip-version-check -r "$MR/moonraker/scripts/moonraker-requirements.txt" \
        || die "Moonraker requirements failed"
    "$MR/moonraker-env/bin/python" -c 'import tornado, sqlite3, ssl, jinja2, PIL, libnacl.sign, streaming_form_data' \
        || die "Moonraker's environment is incomplete"
    git -C "$MR/moonraker" config core.fileMode false
fi
rm -rf "$MR/moonraker.old" "$MR/moonraker-env.old"
trap - EXIT
oc_swap_off
sync
echo "STAGE Moonraker installed"
