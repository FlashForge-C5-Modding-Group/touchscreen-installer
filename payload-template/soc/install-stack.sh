#!/bin/sh
# Printer SoC mode: Kalico in /usr/data/opencreator/klipper/klipper with a
# virtualenv on the hard-float Python in /usr/data/python-hf
# (install-python.sh), and the opencreator-fs printer config in
# /usr/data/opencreator/klipper/config.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

OC=$DEMO_ROOT/usr/data/opencreator/klipper
PYHF=$DEMO_ROOT/usr/data/python-hf
KALICO_REPO=${OC_KALICO_REPO:-https://github.com/FlashForge-C5-Modding-Group/kalico.git}
KALICO_BRANCH=${OC_KALICO_BRANCH:-something}
OPENCREATOR_FS_REPO=${OC_FS_REPO:-https://github.com/FlashForge-C5-Modding-Group/opencreator-fs.git}

die() { echo "ERROR $*"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-fs.XXXXXX") || die "cannot create work directory"
KLIPPER=$OC/klipper

# A fresh Kalico or environment is built next to the current one and
# only swapped in once everything has worked; an existing Kalico checkout is
# updated in place (user files such as AFC's links in klippy/extras stay) and
# reset to its old commit on failure.
OLD_HEAD=
rollback() {
    rm -rf "$OC/klipper.new"
    if [ -d "$OC/klippy-env.old" ]; then
        rm -rf "$OC/klippy-env"
        mv "$OC/klippy-env.old" "$OC/klippy-env"
    fi
    [ -z "$OLD_HEAD" ] || git -C "$OC/klipper" reset -q --hard "$OLD_HEAD" || true
}
trap 'rc=$?; oc_swap_off; rm -rf "$WORK"; [ $rc -eq 0 ] || rollback' EXIT

# A previous run that was interrupted (power loss) left the original aside.
for dir in "$OC/klipper" "$OC/klippy-env"; do
    if [ -d "$dir.old" ]; then
        echo "STAGE Putting back ${dir##*/} from an interrupted install"
        rm -rf "$dir"
        mv "$dir.old" "$dir"
    fi
done

echo "STAGE Downloading the OpenCreator files"
oc_git_clone_shallow "$OPENCREATOR_FS_REPO" "$WORK/opencreator-fs" \
    || die "cannot download opencreator-fs"

if git -C "$OC/klipper" remote get-url origin 2>/dev/null | grep -qi 'kalico'; then
    echo "STAGE Updating Kalico ($KALICO_BRANCH) in place"
    OLD_HEAD=$(git -C "$OC/klipper" rev-parse HEAD) || die "cannot read the Kalico checkout"
    # Changes to Kalico's own files are lost by the update; keep a patch.
    if ! git -C "$OC/klipper" diff --quiet HEAD 2>/dev/null; then
        git -C "$OC/klipper" diff HEAD > "$OC_BACKUP/kalico-local-changes.patch"
        echo "STAGE Your changes to Kalico's files are saved in $OC_BACKUP/kalico-local-changes.patch"
    fi
    git -C "$OC/klipper" remote set-url origin "$KALICO_REPO"
    git -C "$OC/klipper" fetch --depth 1 origin "$KALICO_BRANCH" || die "cannot download Kalico"
    git -C "$OC/klipper" reset -q --hard FETCH_HEAD || die "cannot update Kalico"
else
    echo "STAGE Downloading Kalico ($KALICO_BRANCH)"
    oc_git_clone_shallow "$KALICO_REPO" "$OC/klipper.new" "$KALICO_BRANCH" \
        || die "cannot download Kalico"
    KLIPPER=$OC/klipper.new
fi

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would create $OC/klippy-env with python-hf -m venv" \
         "--without-pip --system-site-packages and build klippy/chelper"
else
    [ -x "$PYHF/bin/python3.13" ] || die "hard-float Python is not installed"
    if grep -qx "home = /usr/data/python-hf/bin" "$OC/klippy-env/pyvenv.cfg" 2>/dev/null &&
        "$OC/klippy-env/bin/python" -c 'import sys' 2>/dev/null; then
        echo "STAGE Kalico's Python environment is up to date"
    else
        echo "STAGE Creating Kalico's Python environment"
        rm -rf "$OC/klippy-env.old"
        [ ! -d "$OC/klippy-env" ] || mv "$OC/klippy-env" "$OC/klippy-env.old"
        "$PYHF/bin/python3.13" -m venv --without-pip --system-site-packages "$OC/klippy-env" \
            || die "cannot create $OC/klippy-env"
        # A c_helper.so from the old (soft-float) Python cannot be loaded.
        rm -f "$KLIPPER/klippy/chelper/c_helper.so"
    fi

    echo "STAGE Building Kalico's C helper"
    # python-hf's cc/bin/gcc builds hard-float code with Entware's gcc; it
    # only rebuilds when the sources changed.
    (cd "$KLIPPER/klippy" && PATH="$PYHF/cc/bin:/opt/bin:$PATH" \
        "$OC/klippy-env/bin/python" -c 'import chelper; chelper.get_ffi()') \
        || die "c_helper.so build failed; check /opt/bin/gcc"
fi

if [ "$KLIPPER" = "$OC/klipper.new" ]; then
    echo "STAGE Installing Kalico to $OC/klipper"
    rm -rf "$OC/klipper.old"
    [ ! -d "$OC/klipper" ] || mv "$OC/klipper" "$OC/klipper.old"
    mv "$OC/klipper.new" "$OC/klipper"
fi
rm -rf "$OC/klipper.old" "$OC/klippy-env.old"
trap 'rm -rf "$WORK"' EXIT
oc_swap_off

echo "STAGE Installing the OpenCreator printer config"
TEMPLATE=$WORK/opencreator-fs/fs/usr/data/config
mkdir -p "$OC/config" "$OC/logs"
(cd "$TEMPLATE" && find . -type d) | while IFS= read -r dir; do
    mkdir -p "$OC/config/$dir"
done
added=0
kept=0
fresh_printer_cfg=0
[ -e "$OC/config/printer.cfg" ] || fresh_printer_cfg=1
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
# A first install takes the printer's calibration from FlashForge's config.
if [ "$fresh_printer_cfg" = 1 ]; then
    /bin/sh "$OC_PAYLOAD/common/import-stock-calibration.sh" \
        "$DEMO_ROOT/usr/data/config/printer.cfg" "$OC/config/printer.cfg"
fi
[ -e "$OC/gcodes" ] || [ -L "$OC/gcodes" ] || ln -s /usr/data/gcodes "$OC/gcodes"
mkdir -p "$DEMO_ROOT/usr/data/gcodes"
sync
echo "STAGE Kalico and config installed"
