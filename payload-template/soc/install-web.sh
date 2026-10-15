#!/bin/sh
# Printer SoC mode: latest Mainsail and Fluidd releases, with nginx
# serving the chosen one on port 80.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
WEB_UI=${1:-${OC_WEB_UI:?}}
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

MAINSAIL_DIR="$DEMO_ROOT/usr/data/mainsail"
FLUIDD_DIR="$DEMO_ROOT/usr/data/fluidd"
NGINX=$DEMO_ROOT/usr/data/nginx
SITE=$NGINX/sites-available/mainsail

die() { echo "ERROR $*"; exit 1; }

install_zip_release() {  # install_zip_release REPO ASSET DEST
    local repo=$1 asset=$2 dest=$3 url WORK
    url=$(oc_github_latest_asset_url "$repo" "$asset")
    [ -n "$url" ] || die "could not find a $asset release asset for $repo"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-web.XXXXXX") || die "cannot create work directory"
    echo "STAGE Downloading $asset from $repo"
    oc_download "$url" "$WORK/$asset" || { rm -rf "$WORK"; die "download failed: $asset"; }
    rm -rf "$dest"
    mkdir -p "$dest"
    unzip -oq "$WORK/$asset" -d "$dest" || { rm -rf "$WORK"; die "cannot unpack $asset"; }
    rm -rf "$WORK"
}

case "$WEB_UI" in
mainsail) WEB_ROOT=/usr/data/mainsail ;;
fluidd) WEB_ROOT=/usr/data/fluidd ;;
*) die "unknown web UI '$WEB_UI' (expected mainsail or fluidd)" ;;
esac

install_zip_release mainsail-crew/mainsail mainsail.zip "$MAINSAIL_DIR"
echo "STAGE Mainsail installed to $MAINSAIL_DIR"
install_zip_release fluidd-core/fluidd fluidd.zip "$FLUIDD_DIR"
echo "STAGE Fluidd installed to $FLUIDD_DIR"

if [ ! -f "$SITE" ]; then
    [ -n "$DEMO_ROOT" ] || die "nginx site $SITE missing"
    mkdir -p "$(dirname "$SITE")"
    printf 'server {\n    listen 80;\n    root /usr/data/mainsail;\n    index index.html;\n}\n' > "$SITE"
fi
sed -i "s#^\([[:space:]]*root[[:space:]]\).*;#\1$WEB_ROOT;#" "$SITE"
grep -q "root $WEB_ROOT;" "$SITE" || die "could not set the nginx web root in $SITE"
mkdir -p "$NGINX/sites-enabled"
ln -sf /usr/data/nginx/sites-available/mainsail "$NGINX/sites-enabled/mainsail"
sync
echo "STAGE nginx serves $WEB_UI on port 80"
