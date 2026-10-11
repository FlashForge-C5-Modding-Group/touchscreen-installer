#!/bin/sh
# Printer SoC mode: install Klipper, Moonraker, and the opencreator-fs
# config/loopscript overlay for real -- shallow git clones plus file
# copies -- instead of assuming the rootfs already ships them.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

KLIPPER_DIR="$DEMO_ROOT/usr/data/klipper"
MOONRAKER_DIR="$DEMO_ROOT/usr/prog/moonraker"
CONFIG_DIR="$DEMO_ROOT/usr/data/config"
STARTUP_DIR="$DEMO_ROOT/usr/data/opencreator/startup"

KLIPPER_REPO=https://github.com/FlashForge-C5-Modding-Group/klipper-c5.git
MOONRAKER_REPO=https://github.com/Arksine/moonraker.git
OPENCREATOR_FS_REPO=https://github.com/FlashForge-C5-Modding-Group/opencreator-fs.git

die() { echo "ERROR $*"; exit 1; }

echo "STAGE Installing Klipper to $KLIPPER_DIR"
oc_git_clone_shallow "$KLIPPER_REPO" "$KLIPPER_DIR"

echo "STAGE Installing Moonraker to $MOONRAKER_DIR"
oc_backup_and_remove "$MOONRAKER_DIR"
oc_git_clone_shallow "$MOONRAKER_REPO" "$MOONRAKER_DIR"

echo "STAGE Installing opencreator-fs configs and loopscript"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-fs.XXXXXX") || die "cannot create work directory"
trap 'rm -rf "$WORK"' EXIT
oc_git_clone_shallow "$OPENCREATOR_FS_REPO" "$WORK/opencreator-fs"
mkdir -p "$CONFIG_DIR" "$STARTUP_DIR"
cp -a "$WORK/opencreator-fs/fs/usr/data/config/." "$CONFIG_DIR/"
cp -a "$WORK/opencreator-fs/fs/usr/data/opencreator/startup/." "$STARTUP_DIR/"
chmod 755 "$STARTUP_DIR"/scripts/*.sh 2>/dev/null || true

echo "STAGE Klipper, Moonraker, and opencreator-fs configs installed"
