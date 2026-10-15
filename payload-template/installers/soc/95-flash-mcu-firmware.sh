#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/common/flash-mcu-firmware.sh
[ -f "$installer" ] || { echo "ERROR Missing MCU firmware installer: $installer"; exit 1; }
echo "STAGE Flashing MCU firmware"
/bin/sh "$installer"
