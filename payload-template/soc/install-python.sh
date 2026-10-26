#!/bin/sh
# Printer SoC mode: the hard-float Python in /usr/data/python-hf (an
# opencreator-fs release asset) that Kalico and Moonraker run on. Skipped
# when the same release is already installed.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

PYHF=$DEMO_ROOT/usr/data/python-hf
PYTHON_HF_URL=${OC_PYTHON_HF_URL:-https://github.com/FlashForge-C5-Modding-Group/opencreator-fs/releases/download/python-3.13-hardfloat-r4/python-hf-c5-release.zip}
CHECK='import ssl, sqlite3, greenlet, cffi, jinja2, serial, numpy'

die() { echo "ERROR $*"; exit 1; }

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
