#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/common/flash-camera-firmware.sh
[ -f "$installer" ] || { echo "ERROR Missing camera firmware installer: $installer"; exit 1; }
echo "STAGE Updating camera firmware"
/bin/sh "$installer" || echo "WARN Camera firmware not updated; the install carries on"
