#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/common/enable-sftp.sh
[ -f "$installer" ] || { echo "ERROR Missing installer: $installer"; exit 1; }
echo "STAGE Enabling SFTP"
/bin/sh "$installer"
