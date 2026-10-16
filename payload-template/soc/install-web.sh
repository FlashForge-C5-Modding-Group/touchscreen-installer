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

# Update Configs (OC_KEEP_WEB=1) only downloads a UI that is missing.
if [ "${OC_KEEP_WEB:-0}" = 1 ] && [ -f "$MAINSAIL_DIR/index.html" ]; then
    echo "STAGE Mainsail already installed"
else
    install_zip_release mainsail-crew/mainsail mainsail.zip "$MAINSAIL_DIR"
    echo "STAGE Mainsail installed to $MAINSAIL_DIR"
fi
if [ "${OC_KEEP_WEB:-0}" = 1 ] && [ -f "$FLUIDD_DIR/index.html" ]; then
    echo "STAGE Fluidd already installed"
else
    install_zip_release fluidd-core/fluidd fluidd.zip "$FLUIDD_DIR"
    echo "STAGE Fluidd installed to $FLUIDD_DIR"
fi

if [ ! -f "$SITE" ]; then
    [ -n "$DEMO_ROOT" ] || die "nginx site $SITE missing"
    mkdir -p "$(dirname "$SITE")"
    printf 'server {\n    listen 80;\n    root /usr/data/mainsail;\n    index index.html;\n}\n' > "$SITE"
fi
sed -i "s#^\([[:space:]]*root[[:space:]]\).*;#\1$WEB_ROOT;#" "$SITE"
grep -q "root $WEB_ROOT;" "$SITE" || die "could not set the nginx web root in $SITE"
mkdir -p "$NGINX/sites-enabled"
ln -sf /usr/data/nginx/sites-available/mainsail "$NGINX/sites-enabled/mainsail"

# A kept, older moonraker.conf may lack an update section for one of the UIs.
MOONRAKER_CONF=$DEMO_ROOT/usr/data/opencreator/klipper/config/moonraker.conf
add_update_entry() {  # add_update_entry NAME REPO PATH
    grep -q "^\[update_manager $1\]" "$MOONRAKER_CONF" && return 0
    echo "STAGE Adding $1 to Moonraker's update manager"
    printf '\n[update_manager %s]\ntype: web\nchannel: stable\nrepo: %s\npath: %s\n' \
        "$1" "$2" "$3" >> "$MOONRAKER_CONF"
}
if [ -f "$MOONRAKER_CONF" ]; then
    grep -q '^\[update_manager\]' "$MOONRAKER_CONF" ||
        printf '\n[update_manager]\nrefresh_interval: 168\nenable_auto_refresh: false\n' >> "$MOONRAKER_CONF"
    # buildroot has no package manager Moonraker supports; without this it
    # shows a warning in the web UI.
    grep -q '^enable_system_updates:' "$MOONRAKER_CONF" ||
        sed -i 's#^\[update_manager\]$#[update_manager]\nenable_system_updates: False#' "$MOONRAKER_CONF"
    # Pages from the printer's own address are always allowed; these cover
    # hostnames. IP wildcards are rejected by Moonraker.
    if ! grep -q '^cors_domains:' "$MOONRAKER_CONF"; then
        echo "STAGE Allowing local hostnames in Moonraker (cors_domains)"
        grep -q '^\[authorization\]' "$MOONRAKER_CONF" ||
            printf '\n[authorization]\n' >> "$MOONRAKER_CONF"
        sed -i 's#^\[authorization\]$#[authorization]\ncors_domains:\n  *://*.local\n  *://*.lan\n  *://localhost\n  *://localhost:*#' "$MOONRAKER_CONF"
    fi
    add_update_entry mainsail mainsail-crew/mainsail /usr/data/mainsail
    add_update_entry fluidd fluidd-core/fluidd /usr/data/fluidd
    if ! grep -q '^\[update_manager opencreator\]' "$MOONRAKER_CONF"; then
        echo "STAGE Adding the OpenCreator configs to Moonraker's update manager"
        printf '\n[update_manager opencreator]\ntype: git_repo\npath: /usr/data/opencreator/opencreator-fs\norigin: https://github.com/FlashForge-C5-Modding-Group/opencreator-fs.git\nprimary_branch: main\nis_system_service: False\n' \
            >> "$MOONRAKER_CONF"
    fi
fi
sync
echo "STAGE nginx serves $WEB_UI on port 80"
