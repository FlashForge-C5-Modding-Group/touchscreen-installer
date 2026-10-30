#!/bin/sh
# Printer SoC mode: the hard-float Python in /usr/data/python-hf (an
# opencreator-fs release asset) that Kalico and Moonraker run on. Skipped
# when the same release is already installed.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

PYHF=$DEMO_ROOT/usr/data/python-hf
PYTHON_HF_URL=${OC_PYTHON_HF_URL:-https://github.com/FlashForge-C5-Modding-Group/opencreator-fs/releases/download/python-3.13-hardfloat-r2/python-hf-c5-release.zip}
CHECK='import ssl, sqlite3, greenlet, cffi, jinja2, serial, numpy'

die() { echo "ERROR $*"; exit 1; }

# AD5X: the Python built for the AD5X (build/python in AD5X-FS). The copy on the USB drive (payload/python,
# put there by make-usb.sh) is used when it is there, otherwise it is downloaded from the AD5X-FS release.
if [ "${OC_MACHINE:-}" = AD5X ]; then
    AD5X_PYTHON_URL=${OC_AD5X_PYTHON_URL:-https://github.com/FlashForge-C5-Modding-Group/AD5X-FS/releases/download/python-3.14.4-r1/ad5x-python-3.14.4-mipsel.tar.gz}
    PKG=$(ls "$OC_PAYLOAD"/python/ad5x-python-*.tar.gz 2>/dev/null | tail -n 1)
    PY=$DEMO_ROOT$OC_HOME/python
    MR=$DEMO_ROOT$OC_HOME/moonraker
    CHECK_PKG='import ssl, zlib, ctypes, bz2, lzma, sqlite3, cffi, greenlet, numpy, jinja2, serial, tornado, PIL, streaming_form_data, libnacl.sign'
    if [ -n "$DEMO_ROOT" ]; then
        echo "STAGE Demo mode: would install ${PKG:-$AD5X_PYTHON_URL} into $PY"
        exit 0
    fi
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-python.XXXXXX") || die "cannot create work directory"
    SWAPPED=
    trap 'rc=$?; rm -rf "$WORK" "$PY.new"; [ $rc -eq 0 ] || [ -z "$SWAPPED" ] || { rm -rf "$PY"; [ ! -d "$PY.old" ] || mv "$PY.old" "$PY"; }' EXIT
    if [ -n "$PKG" ] && [ -f "$PKG.sha256" ]; then
        echo "STAGE Using the AD5X Python on the USB drive"
        SHAFILE=$PKG.sha256
    else
        PKG=
        SHAFILE=$WORK/ad5x-python.sha256
        echo "STAGE The AD5X Python is not on the USB drive; checking the release"
        oc_download "$AD5X_PYTHON_URL.sha256" "$SHAFILE" || die "cannot download $AD5X_PYTHON_URL.sha256"
    fi
    expected=$(cut -d' ' -f1 < "$SHAFILE" | tr -d '\r' | tr 'A-F' 'a-f')
    [ ${#expected} -eq 64 ] || die "the AD5X Python checksum file is not valid"
    if [ "$(cat "$PY/.package-sha256" 2>/dev/null)" = "$expected" ] &&
        LD_LIBRARY_PATH="$PY/lib" "$PY/bin/python3.14" -c "$CHECK_PKG" 2>/dev/null; then
        echo "STAGE The AD5X Python is up to date"
        exit 0
    fi
    # A previous run that was interrupted (power loss) left the original aside.
    if [ -d "$PY.old" ]; then
        echo "STAGE Putting back the AD5X Python from an interrupted install"
        rm -rf "$PY"
        mv "$PY.old" "$PY"
    fi
    if [ -z "$PKG" ]; then
        echo "STAGE Downloading the AD5X Python"
        PKG=$WORK/ad5x-python.tar.gz
        oc_download "$AD5X_PYTHON_URL" "$PKG" || die "cannot download $AD5X_PYTHON_URL"
    fi
    echo "STAGE Checking the AD5X Python package"
    actual=$(sha256_of "$PKG") || die "no working sha256 tool to check the AD5X Python package"
    [ "$actual" = "$expected" ] || die "the AD5X Python package is damaged (checksum mismatch)"
    echo "STAGE Installing the AD5X Python"
    mkdir -p "$(dirname "$PY")"
    mkdir -p "$WORK/unpacked"
    gunzip -c "$PKG" | tar -xf - -C "$WORK/unpacked" || die "cannot unpack the AD5X Python"
    [ -x "$WORK/unpacked/python/bin/python3.14" ] || die "the AD5X Python package has no python3.14"
    rm -rf "$PY.new" "$PY.old"
    mv "$WORK/unpacked/python" "$PY.new" || die "cannot move the AD5X Python into place"
    [ ! -d "$PY" ] || mv "$PY" "$PY.old"
    mv "$PY.new" "$PY"
    SWAPPED=1
    LD_LIBRARY_PATH="$PY/lib" "$PY/bin/python3.14" -c "$CHECK_PKG" || die "the AD5X Python does not run on this printer"
    # Moonraker comes in the same package, next to the Python
    if [ -d "$WORK/unpacked/moonraker" ]; then
        rm -rf "$MR.new"
        mv "$WORK/unpacked/moonraker" "$MR.new" || die "cannot move Moonraker into place"
        rm -rf "$MR"
        mv "$MR.new" "$MR"
    fi
    echo "$expected" > "$PY/.package-sha256"
    rm -rf "$PY.old"
    sync
    echo "STAGE The AD5X Python is installed"
    exit 0
fi


if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would download $PYTHON_HF_URL and unpack it to $PYHF"
    exit 0
fi

# A previous run that was interrupted (power loss) left the original aside.
if [ -d "$PYHF.old" ]; then
    echo "STAGE Putting back python-hf from an interrupted install"
    rm -rf "$PYHF"
    mv "$PYHF.old" "$PYHF"
fi
rm -rf "$PYHF.new" "$PYHF.unpack"

if [ "$(cat "$PYHF/.bundle-url" 2>/dev/null)" = "$PYTHON_HF_URL" ] &&
    "$PYHF/bin/python3.13" -c "$CHECK" 2>/dev/null; then
    echo "STAGE Hard-float Python is up to date"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-python.XXXXXX") || die "cannot create work directory"
rollback() {
    rm -rf "$PYHF.new" "$PYHF.unpack"
    if [ -d "$PYHF.old" ]; then
        rm -rf "$PYHF"
        mv "$PYHF.old" "$PYHF"
    fi
}
trap 'rc=$?; rm -rf "$WORK"; [ $rc -eq 0 ] || rollback' EXIT

echo "STAGE Downloading hard-float Python"
# The release zip holds python-hf-c5.tar.gz and its .sha256.
oc_download "$PYTHON_HF_URL" "$WORK/python-hf.zip" || die "cannot download $PYTHON_HF_URL"
unzip -oq "$WORK/python-hf.zip" -d "$WORK" || die "cannot unzip python-hf"
rm -f "$WORK/python-hf.zip"
BUNDLE=$WORK/python-hf-c5.tar.gz
[ -f "$BUNDLE" ] || die "python-hf-c5.tar.gz missing from the release zip"
if [ -f "$BUNDLE.sha256" ]; then
    (cd "$WORK" && sha256sum -c python-hf-c5.tar.gz.sha256 >/dev/null) \
        || die "python-hf-c5.tar.gz is damaged"
fi

echo "STAGE Installing hard-float Python"
mkdir -p "$PYHF.unpack"
gunzip -c "$BUNDLE" | tar -xf - -C "$PYHF.unpack" || die "cannot unpack python-hf"
rm -f "$BUNDLE"
mv "$PYHF.unpack/python-hf" "$PYHF.new"
echo "$PYTHON_HF_URL" > "$PYHF.new/.bundle-url"
rm -rf "$PYHF.unpack" "$PYHF.old"
[ ! -d "$PYHF" ] || mv "$PYHF" "$PYHF.old"
mv "$PYHF.new" "$PYHF"
"$PYHF/bin/python3.13" -c "$CHECK" || die "hard-float Python does not run on this printer"
rm -rf "$PYHF.old"
trap 'rm -rf "$WORK"' EXIT
sync
echo "STAGE Hard-float Python installed"
