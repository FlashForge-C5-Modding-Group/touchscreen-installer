#!/bin/sh
# Flash the Creator 5's four MCUs (mainBoardGD, heaterBoard, eBoard,
# levelBoard) from a staged firmware package, if they are not already
# running it. Shared by both install modes (dispatched from
# installers/soc/95-flash-mcu-firmware.sh and
# installers/tunnel/95-flash-mcu-firmware.sh) since both depend on
# Kalico MCU firmware already being flashed, regardless of where
# Klipper itself ends up running.
#
# Expects exactly one package at $OC_PAYLOAD/mcu-firmware/*.tgz with a
# matching *.tgz.sha256 and *.tgz.manifest.json sidecar, in the format
# produced by creator-5-update-creator (MCU_MODE=replacement). For
# local testing, copy one of the example packages from the root of the
# Klipperstuffs workspace (e.g. Creator5Pro-all-mcus-<commit>-<date>.tgz
# plus its .manifest.json, with a generated .sha256 sidecar) into
# payload-template/mcu-firmware/.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}

FW_DIR="$OC_PAYLOAD/mcu-firmware"
MARKER="$DEMO_ROOT/usr/data/opencreator/mcu-firmware.commit"
LOG_DIR="$DEMO_ROOT/usr/data/logs"
FF_UPDATE_PASSWORD="${FF_UPDATE_PASSWORD:-FFP0331&*%root}"

die() { echo "ERROR $*"; exit 1; }

# FlashForge's .tgz/.tar.xz members are often plain tar; the printer's
# busybox tar cannot decompress, so pick the method from the magic bytes.
extract() {  # extract ARCHIVE DEST
    magic=$(dd if="$1" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$magic" in
        1f8b) gunzip -c "$1" | tar -xf - -C "$2" ;;
        fd37) xz -dc "$1" | tar -xf - -C "$2" ;;
        *) tar -xf "$1" -C "$2" ;;
    esac
}

if [ ! -d "$FW_DIR" ]; then
    echo "STAGE No MCU firmware payload staged, skipping"
    exit 0
fi

# Like the stock USB update, only a package named for this model is used:
# Creator5Pro-*.tgz on a Creator 5 Pro, Creator5-*.tgz on a Creator 5.
: "${OC_MACHINE:?}"
set -- "$FW_DIR/$OC_MACHINE"-*.tgz
if [ ! -e "$1" ]; then
    echo "STAGE No $OC_MACHINE MCU firmware package in $FW_DIR, skipping"
    exit 0
fi
[ "$#" -eq 1 ] || die "expected one $OC_MACHINE-*.tgz in $FW_DIR, found $#"
PKG=$1
SHA_SIDECAR="$PKG.sha256"
MANIFEST="$PKG.manifest.json"

[ -f "$SHA_SIDECAR" ] || die "missing checksum sidecar: $SHA_SIDECAR"
[ -f "$MANIFEST" ] || die "missing manifest sidecar: $MANIFEST"

echo "STAGE Verifying MCU firmware package checksum"
PKG_NAME=$(basename "$PKG")
expected=$(cut -d' ' -f1 < "$SHA_SIDECAR")
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum < "$PKG" | cut -d' ' -f1)
else
    actual=$(LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib /usr/prog/openssl-1.0.2d/bin/openssl \
        dgst -sha256 < "$PKG" | sed 's/^.*= *//')
fi
[ -n "$expected" ] && [ "$actual" = "$expected" ] || die "checksum mismatch for $PKG_NAME"

COMMIT=$(sed -n 's/.*"commit": *"\([0-9a-f]\{7,40\}\)".*/\1/p' "$MANIFEST" | head -n 1)
[ -n "$COMMIT" ] || die "could not read repository.commit from $MANIFEST"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$COMMIT" ]; then
    echo "STAGE MCU firmware already at commit $COMMIT, skipping"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-mcu-flash.XXXXXX") || die "cannot create work directory"
trap 'rm -rf "$WORK"' EXIT

echo "STAGE Decrypting MCU firmware package"
export PATH=/usr/prog/openssl-1.0.2d/bin:$PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:${LD_LIBRARY_PATH:-}
openssl enc -des-ede3-cbc -d -k "$FF_UPDATE_PASSWORD" -salt -md md5 \
    -in "$PKG" -out "$WORK/outer.tgz" \
    || die "could not decrypt $PKG_NAME (wrong password/format?)"

echo "STAGE Extracting MCU firmware package"
mkdir -p "$WORK/outer"
extract "$WORK/outer.tgz" "$WORK/outer" || die "could not extract outer package"

CONTROL=$(find "$WORK/outer" -maxdepth 1 -name 'control-*.tar.xz' | head -n 1)
[ -n "$CONTROL" ] || die "no control-*.tar.xz found inside $PKG_NAME"
mkdir -p "$WORK/control"
extract "$CONTROL" "$WORK/control" || die "could not extract $CONTROL"

cd "$WORK/control"
if [ -f md5sum.list ]; then
    md5sum -c md5sum.list || die "control package files failed checksum verification"
fi
chmod a+x IAPCommand ISPCommand 2>/dev/null || true

mkdir -p "$LOG_DIR"
FAILED=0

flash_iap() {  # flash_iap LABEL HEX PORT
    label=$1 hex=$2 port=$3
    [ -f "$hex" ] || return 0
    log="$LOG_DIR/UPDATA_FIRMWARE_${label}.log"
    echo "STAGE Flashing $label firmware"
    if [ -n "$DEMO_ROOT" ]; then
        echo "DEMO would run: ./IAPCommand $hex $port" > "$log"
        return 0
    fi
    i=1
    while [ "$i" -le 3 ]; do
        rm -f "$log"
        ./IAPCommand "$hex" "$port" >"$log" 2>&1 || true
        if [ -f "$log" ] && ! grep -qi "error\|fail\|not" "$log"; then
            return 0
        fi
        i=$((i + 1))
    done
    echo "ERROR Flashing $label failed after 3 attempts; see $log"
    FAILED=1
    return 1
}

flash_isp() {  # flash_isp LABEL HEX
    label=$1 hex=$2
    [ -f "$hex" ] || return 0
    log="$LOG_DIR/UPDATA_MCU_${label}.log"
    echo "STAGE Flashing $label firmware"
    if [ -n "$DEMO_ROOT" ]; then
        echo "DEMO would run: ./ISPCommand $hex" > "$log"
        return 0
    fi
    i=1
    while [ "$i" -le 3 ]; do
        rm -f "$log"
        ./ISPCommand "$hex" >"$log" 2>&1 || true
        if [ -f "$log" ] && ! grep -qi "error\|fail\|not" "$log"; then
            return 0
        fi
        i=$((i + 1))
    done
    echo "ERROR Flashing $label failed after 3 attempts; see $log"
    FAILED=1
    return 1
}

# Ports match the printer's own UART wiring (opencreator-tunnel's
# README): ttyS2 mainBoardGD, ttyS4 heaterBoard, ttyS5 eBoard,
# ttyS7 levelBoard.
flash_iap EBOARD_M3 eBoard.hex /dev/ttyS5
flash_iap HEATERBOARD_M3 heaterBoard.hex /dev/ttyS4
flash_iap LEVELBOARD_M3 levelBoard.hex /dev/ttyS7
flash_isp GD_M3 mainBoardGD.hex

[ "$FAILED" -eq 0 ] || die "one or more MCUs failed to flash; firmware not marked as installed"

mkdir -p "$(dirname "$MARKER")"
echo "$COMMIT" >"$MARKER"
echo "STAGE MCU firmware flashed successfully (commit $COMMIT)"
