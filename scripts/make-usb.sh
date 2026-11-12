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
cp "$BIN" "$OUT/opencreator/opencreator-installer"
cp "$ROOT/scripts/install.sh" "$OUT/opencreator/install.sh"
cp -R "$ROOT/payload-template/." "$OUT/opencreator/payload/"
# The earliest the printer's clock can be; see oc_set_clock.
date -u '+%Y-%m-%d %H:%M:%S' > "$OUT/opencreator/payload/build-date"
for pkg in ${MCU_PACKAGE:-}; do
    cp "$pkg" "$pkg.sha256" "$pkg.manifest.json" "$OUT/opencreator/payload/mcu-firmware/"
done
# The printer's busybox sh cannot run CRLF scripts.
find "$OUT" -name '*.sh' -exec sed -i 's/\r$//' {} +

echo "USB files in $OUT:"
(cd "$OUT" && find . -type f | sort)

# The release zip, named like the OpenCreator releases: "Public Alpha 7.2"
# in install.sh gives OpenCreator-Alpha-7.2.zip, beside the folder.
release=$(sed -n 's/^INSTALLER_RELEASE="Public \(.*\)"$/\1/p' "$ROOT/scripts/install.sh")
[ -n "$release" ] || { echo "no INSTALLER_RELEASE in install.sh" >&2; exit 1; }
ZIP=$(dirname "$OUT")/OpenCreator-$(echo "$release" | tr ' ' '-').zip
python3 - "$OUT" "$ZIP" <<'EOF'
import os, sys, zipfile
src, out = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        rel = os.path.relpath(root, src).replace(os.sep, "/")
        if not files and not dirs:
            z.writestr(zipfile.ZipInfo(rel + "/"), "")
        for f in sorted(files):
            path = os.path.join(root, f)
            info = zipfile.ZipInfo.from_file(path, f if rel == "." else rel + "/" + f)
            exe = f.endswith(".sh") or f == "opencreator-installer"
            info.external_attr = (0o100755 if exe else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as fh:
                z.writestr(info, fh.read())
EOF
echo "Release zip: $ZIP"
