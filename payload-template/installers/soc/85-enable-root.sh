#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/common/enable-root.sh
[ -f "$installer" ] || { echo "ERROR Missing installer: $installer"; exit 1; }
echo "STAGE Enabling root login"
/bin/sh "$installer"
