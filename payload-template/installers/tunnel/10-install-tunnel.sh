#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/tunnel/install-tunnel.sh
[ -f "$installer" ] || { echo "ERROR Missing tunnel installer: $installer"; exit 1; }
echo "STAGE Installing Creator 5 tunnel"
/bin/sh "$installer"
