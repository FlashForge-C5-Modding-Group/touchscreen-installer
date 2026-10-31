#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/soc/install-python.sh
[ -f "$installer" ] || { echo "ERROR Missing installer: $installer"; exit 1; }
if [ "${OC_MACHINE:-}" = AD5X ]; then echo "STAGE Installing updated Python"; else echo "STAGE Installing hard-float Python"; fi
/bin/sh "$installer"
