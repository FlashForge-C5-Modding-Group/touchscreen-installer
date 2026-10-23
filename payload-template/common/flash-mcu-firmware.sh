#!/bin/sh
# Flash the Creator 5's four MCUs (mainBoardGD, heaterBoard, eBoard,
# levelBoard) from a staged firmware package, if they are not already
# running it. Shared by both install modes (dispatched from
# installers/soc/95-flash-mcu-firmware.sh and
# installers/tunnel/95-flash-mcu-firmware.sh) since both depend on
# Kalico MCU firmware already being flashed, regardless of where
# Klipper itself ends up running.
#
# Expects packages at $OC_PAYLOAD/mcu-firmware/*.tgz, each with a
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
    magic=$(dd if="$1" bs=1 count=2 2>/dev/null | hexdump -v -e '2/1 "%02x"' 2>/dev/null) || magic=
    case "$magic" in
        1f8b) gunzip -c "$1" | tar -xf - -C "$2" ;;
        fd37) xz -dc "$1" | tar -xf - -C "$2" ;;
        *) tar -xf "$1" -C "$2" ;;
    esac
}

# OC_IGNORE_MCU_CHECKSUM=1 ("Flash anyway"): a package that fails its sha256
# is still flashed, but only if every file inside matches md5sum.list.
IGNORE_SUM=${OC_IGNORE_MCU_CHECKSUM:-0}

if [ ! -d "$FW_DIR" ]; then
    echo "STAGE No MCU firmware payload staged, skipping"
    exit 0
fi

# Like the stock USB update, only a package named for this model is used:
# Creator5Pro-*.tgz on a Creator 5 Pro, Creator5-*.tgz on a Creator 5.
: "${OC_MACHINE:?}"
# With several, the newest build (build_timestamp_utc in its manifest) wins.
PKG=$(for pkg in "$FW_DIR/$OC_MACHINE"-*.tgz; do
    [ -f "$pkg" ] || continue
    built=$(sed -n 's/.*"build_timestamp_utc": *"\([^"]*\)".*/\1/p' "$pkg.manifest.json" 2>/dev/null | head -n 1)
    echo "${built:-0} $pkg"
done | sort | tail -n 1)
newest=${PKG%% *}
PKG=${PKG#* }
[ "$newest" != 0 ] || newest=
if [ -z "$PKG" ]; then
    echo "STAGE No $OC_MACHINE MCU firmware package in $FW_DIR, skipping"
    exit 0
fi
echo "STAGE Using $(basename "$PKG")${newest:+, built $newest}"
SHA_SIDECAR="$PKG.sha256"
MANIFEST="$PKG.manifest.json"

[ -f "$SHA_SIDECAR" ] || die "missing checksum sidecar: $SHA_SIDECAR"
[ -f "$MANIFEST" ] || die "missing manifest sidecar: $MANIFEST"

echo "STAGE Verifying MCU firmware package checksum"
PKG_NAME=$(basename "$PKG")
expected=$(cut -d' ' -f1 < "$SHA_SIDECAR" | tr -d '\r' | tr 'A-F' 'a-f')
# The first tool that prints a real hash wins: a sha256sum on PATH can be a
# broken link or applet left by another mod.
sha256_of() {
    for tool in sha256sum "busybox sha256sum" /opt/bin/sha256sum ff-openssl openssl; do
        case $tool in
            ff-openssl) out=$(LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib \
                /usr/prog/openssl-1.0.2d/bin/openssl dgst -sha256 < "$1" 2>/dev/null | sed 's/^.*= *//') ;;
            openssl) out=$(openssl dgst -sha256 < "$1" 2>/dev/null | sed 's/^.*= *//') ;;
            *) out=$($tool < "$1" 2>/dev/null | cut -d' ' -f1) ;;
        esac
        case $out in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ ${#out} -eq 64 ] && { echo "$out"; return 0; } ;;
        esac
    done
    return 1
}
if ! actual=$(sha256_of "$PKG"); then
    [ "$IGNORE_SUM" = 1 ] || { echo "MCUFORCE"; die "no working sha256 tool to check $PKG_NAME"; }
    echo "WARN No sha256 tool; flashing $PKG_NAME after checking the files inside"
elif [ "$actual" != "$expected" ] && [ "$IGNORE_SUM" = 1 ]; then
    echo "WARN $PKG_NAME failed its checksum; flashing it after checking the files inside"
elif [ "$actual" != "$expected" ]; then
    # A flaky USB read gives a different hash each time; read it once more
    again=$(sha256_of "$PKG")
    size=$(wc -c < "$PKG" | tr -d ' ')
    echo "ERROR expected $expected"
    echo "ERROR got      $actual (again: $again), $size bytes"
    # Lets the installer offer "Flash anyway"
    echo "MCUFORCE"
    [ "$again" = "$actual" ] || die "checksum mismatch for $PKG_NAME: the USB drive gave different data on each read; try another drive"
    die "checksum mismatch for $PKG_NAME: the file on the USB drive is damaged; extract the release zip to the drive again"
fi

COMMIT=$(sed -n 's/.*"commit": *"\([0-9a-f]\{7,40\}\)".*/\1/p' "$MANIFEST" | head -n 1)
[ -n "$COMMIT" ] || die "could not read repository.commit from $MANIFEST"

# Skipped only when the boards are known to run $COMMIT. A FlashForge update
# (stock OTA or USB) reflashes them from its control package without touching
# MARKER, so MARKER also holds the control package it was written next to.
# When Klipper is up, the versions the boards report decide instead.
control_stamp() {
    d=$(for c in "$DEMO_ROOT"/usr/prog/PROGRAM/control/[0-9]*/; do [ -d "$c" ] && basename "$c"; done |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    [ -n "$d" ] || { echo none; return; }
    echo "$d $(stat -c %Y "$DEMO_ROOT/usr/prog/PROGRAM/control/$d" 2>/dev/null || echo 0)"
}
STAMP=$(control_stamp)
SHORT=$(printf '%.8s' "$COMMIT")
reported=$(curl -s -m 5 "http://127.0.0.1:7125/printer/objects/query?mcu=mcu_version&mcu%20eboard=mcu_version&mcu%20eheaterboard=mcu_version&mcu%20levelboard=mcu_version" 2>/dev/null |
    grep -o '"mcu_version": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
if [ -z "$DEMO_ROOT" ] && [ "$(printf '%s\n' "$reported" | grep -c .)" -eq 4 ]; then
    if [ "$(printf '%s\n' "$reported" | grep -c "^$SHORT")" -eq 4 ]; then
        echo "STAGE All four boards report $SHORT, skipping"
        printf '%s\n%s\n' "$COMMIT" "$STAMP" > "$MARKER"
        exit 0
    fi
    echo "STAGE Boards report $(printf '%s ' $reported)- flashing $SHORT"
elif [ -f "$MARKER" ] && [ "$(sed -n 1p "$MARKER")" = "$COMMIT" ] &&
    [ "$(sed -n 2p "$MARKER")" = "$STAMP" ]; then
    echo "STAGE MCU firmware already at commit $COMMIT, skipping"
    exit 0
elif [ -f "$MARKER" ] && [ "$(sed -n 1p "$MARKER")" = "$COMMIT" ]; then
    echo "STAGE FlashForge's control package changed since the last flash (a stock update reflashes the boards); flashing again"
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
elif [ "$IGNORE_SUM" = 1 ]; then
    die "the package has no md5sum.list to check its files against; not flashing it"
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
printf '%s
%s
' "$COMMIT" "$STAMP" >"$MARKER"
echo "STAGE MCU firmware flashed successfully (commit $COMMIT)"
