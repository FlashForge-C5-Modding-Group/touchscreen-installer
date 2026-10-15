#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/tunnel/install-tunnel.sh
[ -f "$installer" ] || { echo "ERROR Missing tunnel installer: $installer"; exit 1; }
echo "STAGE Installing the socat bridge"
/bin/sh "$installer"
