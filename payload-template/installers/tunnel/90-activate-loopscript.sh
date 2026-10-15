#!/bin/sh
set -eu
: "${OC_PAYLOAD:?}"
installer=$OC_PAYLOAD/common/activate-loopscript.sh
[ -f "$installer" ] || { echo "ERROR Missing installer: $installer"; exit 1; }
echo "STAGE Activating LoopScript"
/bin/sh "$installer"
