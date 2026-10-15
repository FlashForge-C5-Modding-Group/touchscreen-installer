#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_TOUCHSCREEN:?}"
[ "$OC_TOUCHSCREEN" = yes ] || { echo "STAGE GrumpyScreen skipped"; exit 0; }
installer=$OC_PAYLOAD/soc/installgrumpy.sh
[ -f "$installer" ] || { echo "ERROR Missing GrumpyScreen installer: $installer"; exit 1; }
echo "STAGE Installing GrumpyScreen touchscreen"
/bin/sh "$installer"
echo "STAGE GrumpyScreen: set host under [moonraker] in /usr/data/grumpyscreen/grumpyscreen.cfg to your SBC's IP"
