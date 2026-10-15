#!/bin/sh
# Printer SoC mode: Kalico in /usr/data/opencreator/klipper/klipper with a
# virtualenv on Entware's Python, and the opencreator-fs printer config in
# /usr/data/opencreator/klipper/config.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

OC=$DEMO_ROOT/usr/data/opencreator/klipper
KALICO_REPO=${OC_KALICO_REPO:-https://github.com/FlashForge-C5-Modding-Group/kalico.git}
KALICO_BRANCH=${OC_KALICO_BRANCH:-something}
OPENCREATOR_FS_REPO=${OC_FS_REPO:-https://github.com/FlashForge-C5-Modding-Group/opencreator-fs.git}

die() { echo "ERROR $*"; exit 1; }

# New Kalico and its environment are built next to the current ones and only
# swapped in once everything has worked; on failure the current ones stay.
rollback() {
    rm -rf "$OC/klipper.new"
    if [ -d "$OC/klippy-env.old" ]; then
        rm -rf "$OC/klippy-env"
        mv "$OC/klippy-env.old" "$OC/klippy-env"
    fi
}
trap 'rc=$?; oc_swap_off; [ $rc -eq 0 ] || rollback' EXIT

# A previous run that was interrupted (power loss) left the original aside.
for dir in klipper klippy-env; do
    if [ -d "$OC/$dir.old" ]; then
        echo "STAGE Putting back $dir from an interrupted install"
        rm -rf "$OC/$dir"
        mv "$OC/$dir.old" "$OC/$dir"
    fi
done

echo "STAGE Downloading Kalico ($KALICO_BRANCH)"
oc_git_clone_shallow "$KALICO_REPO" "$OC/klipper.new" "$KALICO_BRANCH" \
    || die "cannot download Kalico"

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would create $OC/klippy-env with" \
         "/opt/bin/python3 -m virtualenv --system-site-packages, pip-install" \
         "any missing Klippy modules and build klippy/chelper"
else
    echo "STAGE Creating Kalico's Python environment"
    /opt/bin/python3 -m virtualenv --version >/dev/null 2>&1 ||
        oc_run_staged /opt/bin/python3 -m pip install virtualenv || die "cannot install virtualenv"
    rm -rf "$OC/klippy-env.old"
    [ ! -d "$OC/klippy-env" ] || mv "$OC/klippy-env" "$OC/klippy-env.old"
    /opt/bin/python3 -m virtualenv --system-site-packages -p /opt/bin/python3 "$OC/klippy-env" \
        || die "cannot create $OC/klippy-env"
    # Only what Klippy imports, unpinned: the pinned requirements would make
    # pip build numpy from source on the printer.
    missing=
    for pair in cffi:cffi greenlet:greenlet jinja2:jinja2 markupsafe:markupsafe serial:pyserial; do
        "$OC/klippy-env/bin/python" -c "import ${pair%%:*}" 2>/dev/null || missing="$missing ${pair#*:}"
    done
    if [ -n "$missing" ]; then
        echo "STAGE Installing Python packages:$missing (this takes a while)"
        oc_swap_on
        # shellcheck disable=SC2086
        oc_run_staged "$OC/klippy-env/bin/python" -m pip install $missing || die "pip install$missing failed"
    fi
    echo "STAGE Building Kalico's C helper"
    (cd "$OC/klipper.new/klippy" && "$OC/klippy-env/bin/python" -c 'import chelper; chelper.get_ffi()') \
        || die "c_helper.so build failed; check /opt/bin/gcc and /opt/include"
fi

echo "STAGE Installing Kalico to $OC/klipper"
rm -rf "$OC/klipper.old"
[ ! -d "$OC/klipper" ] || mv "$OC/klipper" "$OC/klipper.old"
mv "$OC/klipper.new" "$OC/klipper"
rm -rf "$OC/klipper.old" "$OC/klippy-env.old"
trap - EXIT
oc_swap_off

echo "STAGE Installing the OpenCreator printer config"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-fs.XXXXXX") || die "cannot create work directory"
trap 'rm -rf "$WORK"' EXIT
oc_git_clone_shallow "$OPENCREATOR_FS_REPO" "$WORK/opencreator-fs" \
    || die "cannot download opencreator-fs"
TEMPLATE=$WORK/opencreator-fs/fs/usr/data/config
mkdir -p "$OC/config" "$OC/logs"
(cd "$TEMPLATE" && find . -type d) | while IFS= read -r dir; do
    mkdir -p "$OC/config/$dir"
done
added=0
kept=0
(cd "$TEMPLATE" && find . -type f) > "$WORK/files"
while IFS= read -r file; do
    if [ -e "$OC/config/$file" ]; then
        kept=$((kept + 1))
    else
        cp -p "$TEMPLATE/$file" "$OC/config/$file"
        added=$((added + 1))
    fi
done < "$WORK/files"
echo "STAGE Config: $added files added, $kept existing files kept"
[ -e "$OC/gcodes" ] || [ -L "$OC/gcodes" ] || ln -s /usr/data/gcodes "$OC/gcodes"
mkdir -p "$DEMO_ROOT/usr/data/gcodes"
sync
echo "STAGE Kalico and config installed"
