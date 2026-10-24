#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/soc/detect-dryer.sh
[ -f "$installer" ] || { echo "ERROR Missing installer: $installer"; exit 1; }
echo "STAGE Checking for a filament dryer"
/bin/sh "$installer"
