#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/common/install-entware.sh
[ -f "$installer" ] || { echo "ERROR Missing installer: $installer"; exit 1; }
echo "STAGE Setting up Entware"
/bin/sh "$installer"
