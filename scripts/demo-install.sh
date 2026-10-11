#!/bin/sh
# Runs the OpenCreator installer in demo mode: everything it would
# normally write to the real system instead lands under one throwaway
# directory, so you can inspect exactly what it does without root, a
# real printer, or a real rootfs. See OC_DEMO_ROOT in scripts/install.sh
# and the payload-template/*.sh scripts for how each step redirects.
#
# Usage: demo-install.sh [MODE] [WEB] [TOUCHSCREEN] [DEMO_ROOT]
#   MODE        soc | tunnel          (default: soc)
#   WEB         mainsail | fluidd | none   (default: mainsail, forced to
#               none for tunnel mode)
#   TOUCHSCREEN yes | no               (default: no, forced to no for
#               tunnel mode)
#   DEMO_ROOT   where to write the demo tree (default: ./demo-root,
#               wiped and recreated on every run)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD="$HERE/../payload-template"

MODE=${1:-soc}
WEB=${2:-mainsail}
TOUCHSCREEN=${3:-no}
DEMO_ROOT=${4:-"$HERE/../demo-root"}

if [ "$MODE" = tunnel ]; then
    WEB=none
    TOUCHSCREEN=no
fi

echo "Demo install: mode=$MODE web=$WEB touchscreen=$TOUCHSCREEN"
echo "Writing to: $DEMO_ROOT"

rm -rf "$DEMO_ROOT"
mkdir -p "$DEMO_ROOT/backup"

OC_DEMO_ROOT="$DEMO_ROOT" sh "$HERE/install.sh" install - "$PAYLOAD" \
    "$DEMO_ROOT/backup" "$MODE" "$WEB" "$TOUCHSCREEN"

echo
echo "Done. Files written:"
find "$DEMO_ROOT" -type f | sort
