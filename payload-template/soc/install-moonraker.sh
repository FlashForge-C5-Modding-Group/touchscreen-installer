#!/bin/sh
# Printer SoC mode: current Moonraker in /usr/prog/moonraker/moonraker with
# a virtualenv on the hard-float Python in /usr/data/python-hf. pip builds
# its C extensions with python-hf's gcc wrapper, so they are hard-float too.
# LoopScript's 20-msmr.sh starts it with -d $OC_HOME/klipper.
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

# Old environments a first install removes are archived first; this file
# points at the archive until the install finishes.
ENV_PENDING=$DEMO_ROOT$OC_HOME/.moonraker-envs-pending
restore_envs() {
    [ -f "$ENV_PENDING" ] || return 0
    arch=$(cat "$ENV_PENDING")
    for tgz in "$arch"/*.tar.gz; do
        [ -f "$tgz" ] || continue
        name=${tgz##*/}
        name=${name%.tar.gz}
        echo "STAGE Restoring the old Moonraker environment $name"
        rm -rf "$MR/$name"
        gunzip -c "$tgz" | tar -C "$MR" -xf - || echo "WARN could not restore $name from $tgz"
    done
    rm -f "$ENV_PENDING"
}

# A previous run that was interrupted (power loss) left the original aside.
for dir in moonraker moonraker-env; do
    if [ -d "$MR/$dir.old" ]; then
        echo "STAGE Putting back $dir from an interrupted install"
        rm -rf "$MR/$dir"
        mv "$MR/$dir.old" "$MR/$dir"
    fi
done
restore_envs
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
    restore_envs
    [ -z "$OLD_HEAD" ] || git -C "$MR/moonraker" reset -q --hard "$OLD_HEAD" || true
}
trap 'rc=$?; oc_swap_off; [ $rc -eq 0 ] || rollback' EXIT
rm -rf "$MR/moonraker.old" "$MR/moonraker-env.old"

# First install: old Moonraker environments (FlashForge's soft-float one, or
# copies other mods left) are archived into the backup and removed, not set
# aside; /usr/prog has no room for two. A failed install restores them.
ENV_ARCHIVE=$OC_BACKUP/old-moonraker-envs
if [ "${OC_UPDATE:-0}" = 0 ]; then
    for env in "$MR"/*; do
        [ -f "$env/pyvenv.cfg" ] || [ -f "$env/bin/activate" ] || continue
        if [ "$env" = "$MR/moonraker-env" ] &&
            grep -qx "home = /usr/data/python-hf/bin" "$env/pyvenv.cfg" 2>/dev/null; then
            continue
        fi
        name=${env##*/}
        echo "STAGE Backing up the old Moonraker environment $name"
        mkdir -p "$ENV_ARCHIVE" "$(dirname "$ENV_PENDING")"
        tar -C "$MR" -cf - "$name" | gzip > "$ENV_ARCHIVE/$name.tar.gz.tmp" &&
            gunzip -t "$ENV_ARCHIVE/$name.tar.gz.tmp" &&
            mv "$ENV_ARCHIVE/$name.tar.gz.tmp" "$ENV_ARCHIVE/$name.tar.gz" || {
            rm -f "$ENV_ARCHIVE/$name.tar.gz.tmp"
            die "could not back up $name to $ENV_ARCHIVE (out of space?)"
        }
        echo "$ENV_ARCHIVE" > "$ENV_PENDING"
        echo "STAGE Removing the old Moonraker environment $name"
        rm -rf "$env" || die "could not remove $name"
    done
fi

if git -C "$MR/moonraker" remote get-url origin 2>/dev/null | grep -q Arksine; then
    echo "STAGE Updating Moonraker in place"
    OLD_HEAD=$(git -C "$MR/moonraker" rev-parse HEAD) || die "cannot read the Moonraker checkout"
    # HEAD: the default branch, even if this copy was cloned pinned to an old branch or tag
    git -C "$MR/moonraker" fetch --depth 1 origin HEAD || die "cannot download Moonraker"
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
    # Wheels Entware's Python 3.13 built carry the same tag (cp313
    # linux_mips) but are soft-float: hard-float pip gets its own cache, and
    # the old one goes.
    rm -rf "$HOME/.cache/pip"
    # SKIP_CYTHON: zeroconf as plain Python, not compiled. Pillow looks for
    # zlib and libjpeg in CFLAGS/LDFLAGS, not in the gcc wrapper's paths.
    oc_run_staged env SKIP_CYTHON=1 CFLAGS="-I$PYHF/include" LDFLAGS="-L$PYHF/lib" \
        PIP_CACHE_DIR="$HOME/.cache/pip-hf" "$MR/moonraker-env/bin/python" -m pip install \
        --disable-pip-version-check -r "$MR/moonraker/scripts/moonraker-requirements.txt" \
        || die "Moonraker requirements failed"
    if [ -x /opt/bin/readelf ]; then
        for so in $(find "$MR/moonraker-env" -name '*.so'); do
            /opt/bin/readelf -A "$so" 2>/dev/null | grep -q 'Hard float' ||
                die "not hard-float: ${so#$MR/moonraker-env/}"
        done
    fi
    "$MR/moonraker-env/bin/python" -c 'import tornado, sqlite3, ssl, jinja2, PIL, libnacl.sign, streaming_form_data' \
        || die "Moonraker's environment is incomplete"
    git -C "$MR/moonraker" config core.fileMode false
fi
rm -rf "$MR/moonraker.old" "$MR/moonraker-env.old"
# Installed: a "no backup" copy goes to free its space, a real backup stays.
rm -f "$ENV_PENDING"
case "$OC_BACKUP" in */no-backup) rm -rf "$ENV_ARCHIVE" ;; esac
trap - EXIT
oc_swap_off
sync
echo "STAGE Moonraker installed"
