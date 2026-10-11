#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
: "${OC_WEB_UI:?}"
installer=$OC_PAYLOAD/soc/install-web.sh
[ -f "$installer" ] || { echo "ERROR Missing web UI installer: $installer"; exit 1; }
echo "STAGE Installing $OC_WEB_UI"
/bin/sh "$installer" "$OC_WEB_UI"
