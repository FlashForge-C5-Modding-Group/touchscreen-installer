#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_TOUCHSCREEN:?}"
if [ "$OC_TOUCHSCREEN" != helix ]; then
    # 41-helixscreen.sh only starts an executable binary.
    HELIX=${OC_DEMO_ROOT:-}/usr/data/helixscreen/bin/helix-screen
    if [ -x "$HELIX" ]; then
        chmod 644 "$HELIX"
        echo "STAGE HelixScreen turned off (kept on the printer)"
    else
        echo "STAGE HelixScreen skipped"
    fi
    exit 0
fi
installer=$OC_PAYLOAD/soc/installhelix.sh
[ -f "$installer" ] || { echo "ERROR Missing HelixScreen installer: $installer"; exit 1; }
echo "STAGE Installing HelixScreen touchscreen"
/bin/sh "$installer"
echo "STAGE HelixScreen: its setup wizard asks for your SBC's Moonraker address on the first start"
