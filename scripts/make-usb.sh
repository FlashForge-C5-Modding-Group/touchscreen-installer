#!/bin/sh
# Assembles the files for a FAT32 installer USB drive (copy the contents of
# the output folder to the drive's root). Usage: make-usb.sh [OUT]
# MCU_PACKAGE="a.tgz b.tgz" also adds MCU firmware packages (named Creator5-*
# or Creator5Pro-*, one per model), each with its
# .sha256 and .manifest.json sidecars.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/dist/usb}
BIN=$ROOT/build/mips32/opencreator-installer

[ -f "$BIN" ] || { echo "missing $BIN; run make mips32 first" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/opencreator/payload" "$OUT/opencreator/backups"
cp "$ROOT/scripts/runFirmwareExe.sh" "$OUT/runFirmwareExe.sh"
# the AD5X boot hook runs /mnt/flashforge_init.sh instead
cp "$ROOT/scripts/runFirmwareExe.sh" "$OUT/flashforge_init.sh"
cp "$BIN" "$OUT/opencreator/opencreator-installer"
cp "$ROOT/scripts/install.sh" "$OUT/opencreator/install.sh"
cp -R "$ROOT/payload-template/." "$OUT/opencreator/payload/"
for pkg in ${MCU_PACKAGE:-}; do
    cp "$pkg" "$pkg.sha256" "$pkg.manifest.json" "$OUT/opencreator/payload/mcu-firmware/"
done
# The printer's busybox sh cannot run CRLF scripts.
find "$OUT" -name '*.sh' -exec sed -i 's/\r$//' {} +

echo "USB files in $OUT:"
(cd "$OUT" && find . -type f | sort)
