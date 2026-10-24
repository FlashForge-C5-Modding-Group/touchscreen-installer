#!/bin/sh
# Downloads the latest GrumpyScreen release binary (always named
# "grumpyscreen", no archive) directly from GitHub releases, verifies
# it's actually an ELF binary, and installs it.
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_BACKUP:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

# The AD5X runs the NaN2008 build from grumpy-ff; the C5 build is legacy
# NaN, which only works after the fixnan switch the AD5X does not have.
if [ "${OC_MACHINE:-}" = AD5X ]; then
    REPO=FlashForge-C5-Modding-Group/grumpy-ff
    ASSET=grumpyscreen-ff.tar.gz
else
    REPO=FlashForge-C5-Modding-Group/grumpyscreen
    ASSET=grumpyscreen
fi
destination="$DEMO_ROOT/usr/data/grumpyscreen"

die() { echo "ERROR $*"; exit 1; }

url=$(oc_github_latest_asset_url "$REPO" "$ASSET")
[ -n "$url" ] || die "could not find a $ASSET release asset for $REPO"

tag=$(basename "$(dirname "$url")")
mkdir -p "$destination"
if [ -f "$destination/grumpyscreen" ] &&
    grep -q "\"version\": \"$tag\"" "$destination/release_info.json" 2>/dev/null; then
    echo "STAGE GrumpyScreen $tag already installed"
else
    if [ -f "$destination/grumpyscreen" ]; then
        cp -p "$destination/grumpyscreen" "$OC_BACKUP/grumpyscreen.previous"
    fi
    echo "STAGE Downloading latest GrumpyScreen release"
    if [ "${OC_MACHINE:-}" = AD5X ]; then
        # grumpy-ff ships a tarball: grumpyscreen/{grumpyscreen,grumpyscreen.cfg,start.sh,VERSION}
        rm -rf "$destination/unpack"
        mkdir -p "$destination/unpack"
        oc_download "$url" "$destination/unpack/gs.tar.gz"
        # the printer's tar cannot decompress on its own
        gunzip -c "$destination/unpack/gs.tar.gz" | tar -xf - -C "$destination/unpack" \
            || die "cannot unpack $ASSET"
        new=$destination/unpack/grumpyscreen/grumpyscreen
        magic=$(dd if="$new" bs=1 skip=1 count=3 2>/dev/null)
        [ "$magic" = ELF ] || die "downloaded GrumpyScreen binary is not ELF"
        chmod 755 "$new"
        mv "$new" "$destination/grumpyscreen"
        for f in start.sh VERSION; do
            [ ! -f "$destination/unpack/grumpyscreen/$f" ] || \
                cp "$destination/unpack/grumpyscreen/$f" "$destination/$f"
        done
        [ ! -f "$destination/start.sh" ] || chmod 755 "$destination/start.sh"
        # keep an existing config (40-grumpyscreen.sh sets the AD5X bits)
        [ -f "$destination/grumpyscreen.cfg" ] || \
            cp "$destination/unpack/grumpyscreen/grumpyscreen.cfg" "$destination/grumpyscreen.cfg" 2>/dev/null || true
        rm -rf "$destination/unpack"
    else
        oc_download "$url" "$destination/grumpyscreen.new"
        magic=$(dd if="$destination/grumpyscreen.new" bs=1 skip=1 count=3 2>/dev/null)
        [ "$magic" = ELF ] || die "downloaded GrumpyScreen binary is not ELF"
        chmod 755 "$destination/grumpyscreen.new"
        mv "$destination/grumpyscreen.new" "$destination/grumpyscreen"
    fi
fi

# Moonraker's update manager ("executable" type) reads the installed version
# from here and compares it with the latest release's tag.
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
