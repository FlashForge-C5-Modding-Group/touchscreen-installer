#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/soc/install-stack.sh
[ -f "$installer" ] || { echo "ERROR Missing SoC stack installer: $installer"; exit 1; }
echo "STAGE Installing Kalico on printer SoC"
/bin/sh "$installer"
