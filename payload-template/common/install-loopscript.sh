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

OPENCREATOR_FS_REPO=${OC_FS_REPO:-https://github.com/FlashForge-C5-Modding-Group/opencreator-fs.git}
OCDIR=$DEMO_ROOT/usr/data/opencreator
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
for part in startup firmware tunneled moonraker fluidd; do
    [ -d "$FS/opencreator/$part" ] || continue
    rm -rf "$OCDIR/$part"
    cp -a "$FS/opencreator/$part" "$OCDIR/$part"
done
cp "$FS/opencreator/version.txt" "$OCDIR/version.txt"
chmod 755 "$OCDIR/startup/startup.sh" "$OCDIR"/startup/scripts/*.sh "$OCDIR/firmware/firmwareExe"
chmod 644 "$OCDIR/tunneled/tunneled.sh"

mkdir -p "$NGINX_CONF_D"
cp "$FS"/nginx/conf.d/*.conf "$NGINX_CONF_D/"

if [ "$TOUCHSCREEN" = yes ] && [ ! -f "$GRUMPY_DIR/grumpyscreen.cfg" ]; then
    mkdir -p "$GRUMPY_DIR"
    cp "$FS/grumpyscreen/grumpyscreen.cfg" "$GRUMPY_DIR/grumpyscreen.cfg"
fi

sync
echo "STAGE LoopScript files installed (activated at the end)"
