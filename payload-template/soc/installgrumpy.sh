#!/bin/sh
# Downloads the latest GrumpyScreen release binary (always named
# "grumpyscreen", no archive) directly from GitHub releases, verifies
# it's actually an ELF binary, and installs it.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

REPO=FlashForge-C5-Modding-Group/grumpyscreen
ASSET=grumpyscreen
destination="$DEMO_ROOT/usr/data/grumpyscreen"

die() { echo "ERROR $*"; exit 1; }

url=$(oc_github_latest_asset_url "$REPO" "$ASSET")
[ -n "$url" ] || die "could not find a $ASSET release asset for $REPO"

mkdir -p "$destination"
if [ -f "$destination/grumpyscreen" ]; then
    cp -p "$destination/grumpyscreen" "$OC_BACKUP/grumpyscreen.previous"
fi

echo "STAGE Downloading latest GrumpyScreen release"
oc_download "$url" "$destination/grumpyscreen.new"
magic=$(dd if="$destination/grumpyscreen.new" bs=1 skip=1 count=3 2>/dev/null)
[ "$magic" = ELF ] || die "downloaded GrumpyScreen binary is not ELF"
chmod 755 "$destination/grumpyscreen.new"
mv "$destination/grumpyscreen.new" "$destination/grumpyscreen"

# Moonraker's update manager ("executable" type) reads the installed version
# from here and compares it with the latest release's tag.
tag=$(basename "$(dirname "$url")")
printf '{"project_name": "grumpyscreen", "project_owner": "%s", "version": "%s", "asset_name": "%s"}\n' \
    "${REPO%%/*}" "$tag" "$ASSET" > "$destination/release_info.json"
MOONRAKER_CONF=$DEMO_ROOT/usr/data/opencreator/klipper/config/moonraker.conf
if [ "${OC_MODE:-}" = soc ] && [ -f "$MOONRAKER_CONF" ] &&
    ! grep -q '^\[update_manager grumpyscreen\]' "$MOONRAKER_CONF"; then
    echo "STAGE Adding GrumpyScreen to Moonraker's update manager"
    printf '\n[update_manager grumpyscreen]\ntype: executable\nchannel: stable\nrepo: %s\npath: /usr/data/grumpyscreen\nis_system_service: False\n' \
        "$REPO" >> "$MOONRAKER_CONF"
fi
sync
echo "STAGE GrumpyScreen installed"
