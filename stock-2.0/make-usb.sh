#!/bin/sh
# Builds the standalone stock 2.0 USB drive from the public firmware archives.
# Usage: make-usb.sh [OUT] (default dist/stock-2.0-usb). Needs git, tar, python3.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=${1:-$ROOT/dist/stock-2.0-usb}
ARCHIVES=${OC_FF_ARCHIVES:-$HOME/ffarch}
TEMPLATE=${OC_FF_TEMPLATE:-$ROOT/../creator-5-update-creator/template}
SOFTWARE=2.0.0
CONTROL=1.3.1

die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$ARCHIVES"
for repo in creator-5-firmware-archive creator-5-pro-firmware-archive; do
    if [ ! -d "$ARCHIVES/$repo/.git" ]; then
        GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --filter=blob:none --sparse \
            "https://github.com/FlashForge-C5-Modding-Group/$repo.git" "$ARCHIVES/$repo"
    fi
    git -C "$ARCHIVES/$repo" sparse-checkout set control software
done

rm -rf "$OUT"
mkdir -p "$OUT/stock-2.0"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

for model in Creator5 Creator5Pro; do
    case $model in
        Creator5) src=$ARCHIVES/creator-5-firmware-archive ;;
        *) src=$ARCHIVES/creator-5-pro-firmware-archive ;;
    esac
    sw=$src/software
    list=$sw/md5sum.list
    grep -q "^MACHINE=$model\$" "$sw/app_startup.sh" || die "$model: app_startup.sh is for another model"
    grep -q "  ./control/$CONTROL/eBoard.hex\$" "$list" || die "$model: archive isn't software $SOFTWARE with control $CONTROL"

    # Every file FlashForge's own list covers must match it byte for byte.
    check() {   # check FILE LISTED_PATH
        want=$(awk -v p="./$2" '$2 == p { print $1 }' "$list")
        [ -n "$want" ] || die "$model: $2 isn't in FlashForge's md5sum.list"
        [ "$(md5sum < "$1" | cut -d' ' -f1)" = "$want" ] || die "$model: $2 doesn't match FlashForge's md5sum.list"
    }
    for f in "$src"/control/*; do check "$f" "control/$CONTROL/$(basename "$f")"; done
    (cd "$sw" && for g in 8821cu.ko app_startup.sh bin/* auth/* klipper/start.sh klipper/klipper_pri.sh \
        klipper/config/*; do check "$sw/$g" "$g"; done) || exit 1

    c=$STAGE/$model/control s=$STAGE/$model/software
    mkdir -p "$c" "$s/klipper"
    cp -a "$src/control/." "$c/"
    cp -a "$sw/8821cu.ko" "$sw/app_startup.sh" "$sw/bin" "$sw/auth" "$s/"
    cp -a "$sw/klipper/klippy" "$sw/klipper/extras" "$sw/klipper/kinematics" "$sw/klipper/config" \
        "$sw/klipper/start.sh" "$sw/klipper/klipper_pri.sh" "$s/klipper/"
    cp -a "$sw/klipper/chelper/chelper" "$s/klipper/chelper"
    cp -a "$sw/firmwareExe/firmwareExe" "$s/firmwareExe"
    [ "$(dd if="$s/firmwareExe" bs=1 skip=1 count=3 2>/dev/null)" = ELF ] || die "$model: firmwareExe isn't an ELF"
    # The stock boot's fallback unzips software/<version>/firmwareExe.zip.
    python3 - "$s/firmwareExe" "$s/firmwareExe.zip" <<'EOF'
import sys, zipfile
info = zipfile.ZipInfo("firmwareExe", (2026, 1, 1, 0, 0, 0))
info.external_attr = 0o100755 << 16
info.compress_type = zipfile.ZIP_DEFLATED
with zipfile.ZipFile(sys.argv[2], "w") as z, open(sys.argv[1], "rb") as f:
    z.writestr(info, f.read())
EOF
    find "$STAGE/$model" -name __pycache__ -prune -exec rm -rf {} +

    dest=$OUT/stock-2.0/$model
    mkdir -p "$dest"
    for part in control software; do
        (cd "$STAGE/$model/$part" && find . -type f ! -name md5sum.list | sort | xargs md5sum > md5sum.list)
        tar --format=gnu --owner=0 --group=0 --numeric-owner -cf "$dest/$part.tar" -C "$STAGE/$model/$part" .
    done
    (cd "$dest" && md5sum control.tar software.tar > md5sum.list)
done

cp "$HERE/runFirmwareExe.sh" "$OUT/runFirmwareExe.sh"
sed -i 's/\r$//' "$OUT/runFirmwareExe.sh"
for img in start.img end.img; do
    [ ! -f "$TEMPLATE/$img" ] || cp "$TEMPLATE/$img" "$OUT/$img"
done
echo "Stock 2.0 USB files in $OUT:"
(cd "$OUT" && find . -type f | sort | xargs ls -la | awk '{print $5, $9}')
