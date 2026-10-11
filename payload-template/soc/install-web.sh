#!/bin/sh
# Printer SoC mode: install the chosen web UI's latest pre-built
# release (there's no build toolchain on the printer, so this fetches
# the built dist zip, not source) to its real destination.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
WEB_UI=${1:-${OC_WEB_UI:?}}
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

MAINSAIL_DIR="$DEMO_ROOT/usr/prog/mainsail"
FLUIDD_DIR="$DEMO_ROOT/usr/data/fluidd"

die() { echo "ERROR $*"; exit 1; }

install_zip_release() {  # install_zip_release REPO ASSET DEST
    local repo=$1 asset=$2 dest=$3 url WORK
    url=$(oc_github_latest_asset_url "$repo" "$asset")
    [ -n "$url" ] || die "could not find a $asset release asset for $repo"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-web.XXXXXX") || die "cannot create work directory"
    trap 'rm -rf "$WORK"' EXIT
    echo "STAGE Downloading $asset from $repo"
    oc_download "$url" "$WORK/$asset"
    mkdir -p "$dest"
    unzip -oq "$WORK/$asset" -d "$dest"
    rm -rf "$WORK"
    trap - EXIT
}

case "$WEB_UI" in
mainsail)
    oc_backup_and_remove "$MAINSAIL_DIR"
    install_zip_release mainsail-crew/mainsail mainsail.zip "$MAINSAIL_DIR"
    echo "STAGE Mainsail installed to $MAINSAIL_DIR"
    ;;
fluidd)
    oc_backup_and_remove "$FLUIDD_DIR"
    install_zip_release fluidd-core/fluidd fluidd.zip "$FLUIDD_DIR"
    echo "STAGE Fluidd installed to $FLUIDD_DIR"
    ;;
none)
    echo "STAGE No web UI requested, skipping"
    ;;
*)
    die "unknown web UI '$WEB_UI' (expected mainsail, fluidd, or none)"
    ;;
esac
