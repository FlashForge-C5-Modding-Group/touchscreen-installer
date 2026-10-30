#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/soc/install-afc.sh
[ -f "$installer" ] || { echo "ERROR Missing AFC installer: $installer"; exit 1; }
/bin/sh "$installer"
