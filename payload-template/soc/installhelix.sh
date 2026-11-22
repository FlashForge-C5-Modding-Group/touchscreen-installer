#!/bin/sh
# Installs HelixScreen's MIPS build (static binaries for the Ingenic SoC) from
# its newest GitHub release that has one, betas included. Only the 1.1
# prereleases ship it, so Moonraker's updater has to follow the beta channel.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

REPO=prestonbrown/helixscreen
destination="$DEMO_ROOT/usr/data/helixscreen"
GRUMPY=$DEMO_ROOT/usr/data/grumpyscreen/grumpyscreen
# Kept over an update, as HelixScreen's own installer does.
USER_FILES="settings.json helixscreen.env .disabled_services tool_spools.json crash_history.json user_filaments.json"

die() { echo "ERROR $*"; exit 1; }

# /releases is newest first and includes prereleases, unlike /releases/latest.
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=10" |
    tr ',' '\n' |
    sed -n 's#.*"browser_download_url": *"\([^"]*/helixscreen-mips\.zip\)".*#\1#p' |
    head -n 1)
[ -n "$url" ] || die "could not find a HelixScreen MIPS release on $REPO"
tag=$(basename "$(dirname "$url")")

if [ -x "$destination/bin/helix-screen" ] &&
    grep -q "\"version\": *\"$tag\"" "$destination/release_info.json" 2>/dev/null; then
    echo "STAGE HelixScreen $tag already installed"
else
    # About 60 MB: downloaded to /usr/data, as /tmp is in RAM.
    work="$DEMO_ROOT/usr/data/.helixscreen-install"
    rm -rf "$work"
    mkdir -p "$work"
    trap 'rm -rf "$work"' EXIT
    echo "STAGE Downloading HelixScreen $tag"
    oc_download "$url" "$work/helixscreen.zip"
    echo "STAGE Unpacking HelixScreen $tag"
    new=$work/helixscreen
    mkdir -p "$new"
    unzip -q -o "$work/helixscreen.zip" -d "$new" || die "could not unpack HelixScreen $tag"
    rm -f "$work/helixscreen.zip"
    magic=$(dd if="$new/bin/helix-screen" bs=1 skip=1 count=3 2>/dev/null)
    [ "$magic" = ELF ] || die "downloaded HelixScreen binary is not ELF"
    mkdir -p "$new/config"
    if [ -d "$destination" ]; then
        for f in $USER_FILES; do
            [ ! -f "$destination/config/$f" ] || cp -p "$destination/config/$f" "$new/config/$f"
        done
        [ ! -d "$destination/cache" ] || mv "$destination/cache" "$new/cache"
        rm -rf "$OC_BACKUP/helixscreen.previous"
        mv "$destination" "$OC_BACKUP/helixscreen.previous"
    else
        # No bundled settings: the setup wizard detects the C5's.
        if [ "${OC_MODE:-}" = soc ]; then
            printf '{\n  "wizard_completed": false,\n  "moonraker_host": "127.0.0.1",\n  "moonraker_port": 7125,\n  "display": {\n    "animations_enabled": false\n  }\n}\n' \
                > "$new/config/settings.json"
        else
            printf '{\n  "wizard_completed": false,\n  "display": {\n    "animations_enabled": false\n  }\n}\n' \
                > "$new/config/settings.json"
        fi
    fi
    chmod 755 "$new"/bin/*
    mv "$new" "$destination"
    rm -rf "$work"
    trap - EXIT
fi
chmod 755 "$destination/bin/helix-screen"

# One screen at a time: 40-grumpyscreen.sh only starts an executable binary.
if [ -f "$GRUMPY" ] && [ -x "$GRUMPY" ]; then
    chmod 644 "$GRUMPY"
    echo "STAGE GrumpyScreen turned off (kept on the printer)"
fi

# Moonraker's "web" type reads release_info.json (shipped in the release).
# It must follow the beta channel: stable releases have no MIPS build, so on
# stable it finds no asset to update with.
MOONRAKER_CONF=$DEMO_ROOT/usr/data/opencreator/klipper/config/moonraker.conf
if [ "${OC_MODE:-}" = soc ] && [ -f "$MOONRAKER_CONF" ]; then
    if ! grep -q '^\[update_manager helixscreen\]' "$MOONRAKER_CONF"; then
        echo "STAGE Adding HelixScreen to Moonraker's update manager"
        printf '\n[update_manager helixscreen]\ntype: web\nchannel: beta\nrepo: %s\npath: /usr/data/helixscreen\n' \
            "$REPO" >> "$MOONRAKER_CONF"
    elif sed -n '/^\[update_manager helixscreen\]/,/^\[/p' "$MOONRAKER_CONF" |
            grep -q '^channel: *stable'; then
        echo "STAGE Moving HelixScreen's updates to the beta channel"
        sed -i '/^\[update_manager helixscreen\]/,/^\[/ s/^channel: *stable *$/channel: beta/' "$MOONRAKER_CONF"
    fi
fi
sync
echo "STAGE HelixScreen $tag installed"
