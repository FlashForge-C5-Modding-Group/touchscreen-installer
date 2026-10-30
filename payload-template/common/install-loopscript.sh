#!/bin/sh
# opencreator-fs LoopScript: firmwareExe -> startup/startup.sh ->
# startup/scripts/*.sh (SoC), or firmwareExe -> tunneled/tunneled.sh
# (Tunneled; enabled by tunnel/install-tunnel.sh).
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
TOUCHSCREEN=${OC_TOUCHSCREEN:-no}
. "$OC_PAYLOAD/common/install-helpers.sh"

# the AD5X filesystem lives in its own repo
if [ "${OC_MACHINE:-}" = AD5X ]; then
    OPENCREATOR_FS_REPO=${OC_FS_REPO:-https://github.com/FlashForge-C5-Modding-Group/AD5X-FS.git}
else
    OPENCREATOR_FS_REPO=${OC_FS_REPO:-https://github.com/FlashForge-C5-Modding-Group/opencreator-fs.git}
fi
OCDIR=$DEMO_ROOT$OC_HOME
NGINX_CONF_D=$DEMO_ROOT/usr/data/nginx/conf.d
GRUMPY_DIR=$DEMO_ROOT/usr/data/grumpyscreen

die() { echo "ERROR $*"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-fs.XXXXXX") || die "cannot create work directory"
trap 'rm -rf "$WORK"' EXIT
oc_git_clone_shallow "$OPENCREATOR_FS_REPO" "$WORK/opencreator-fs" \
    || die "cannot download opencreator-fs"
FS=$WORK/opencreator-fs/fs/usr/data
# SoC: the clone stays for Moonraker's [update_manager opencreator], which
# 99-opencreator-updater.sh merges config updates from.
if [ "${OC_MODE:-}" = soc ]; then
    rm -rf "$OCDIR/opencreator-fs"
    mkdir -p "$OCDIR"
    mv "$WORK/opencreator-fs" "$OCDIR/opencreator-fs"
    FS=$OCDIR/opencreator-fs/fs/usr/data
fi

echo "STAGE Installing LoopScript"
mkdir -p "$OCDIR"
# Laid over the installed folders: extra files (custom startup scripts and
# such) stay, see oc_overlay.
for part in startup firmware tunneled moonraker fluidd plugin-manager mcu-flash loadcell afc-ifs; do
    [ -d "$FS/opencreator/$part" ] || continue
    oc_overlay "$FS/opencreator/$part" "$OCDIR/$part" "$OCDIR/.installed/$part.md5"
done
cp "$FS/opencreator/version.txt" "$OCDIR/version.txt"
chmod 755 "$OCDIR/startup/startup.sh" "$OCDIR"/startup/scripts/*.sh "$OCDIR/firmware/firmwareExe"
[ ! -f "$OCDIR/plugin-manager/oc-plugin" ] || chmod 755 "$OCDIR/plugin-manager/oc-plugin"
[ ! -f "$OCDIR/mcu-flash/oc-mcu-flash" ] || chmod 755 "$OCDIR/mcu-flash/oc-mcu-flash"
[ ! -f "$OCDIR/loadcell/loadcell.sh" ] || chmod 755 "$OCDIR/loadcell/loadcell.sh"
[ ! -f "$OCDIR/tunneled/tunneled.sh" ] || chmod 644 "$OCDIR/tunneled/tunneled.sh"

[ ! -d "$FS/nginx/conf.d" ] || \
    oc_overlay "$FS/nginx/conf.d" "$NGINX_CONF_D" "$OCDIR/.installed/nginx-conf.d.md5"

# the AD5X fs ships no default grumpyscreen.cfg; the grumpy-ff release has one
if [ "$TOUCHSCREEN" = yes ] && [ ! -f "$GRUMPY_DIR/grumpyscreen.cfg" ] &&
    [ -f "$FS/grumpyscreen/grumpyscreen.cfg" ]; then
    mkdir -p "$GRUMPY_DIR"
    cp "$FS/grumpyscreen/grumpyscreen.cfg" "$GRUMPY_DIR/grumpyscreen.cfg"
fi

sync
echo "STAGE LoopScript files installed (activated at the end)"
