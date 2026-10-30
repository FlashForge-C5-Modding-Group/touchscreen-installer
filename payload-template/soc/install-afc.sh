#!/bin/sh
# AD5X: the AFC add-on (AFC-Klipper-Add-On) at a pinned commit, without .git, in
# /usr/data/AFC-Klipper-Add-On, and its macros next to AFC.cfg. Its modules are linked into
# Kalico's extras by startup/scripts/10-klipper.sh on every start.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"

[ "${OC_MACHINE:-}" = AD5X ] || exit 0

AFC_REPO=${OC_AFC_REPO:-https://github.com/ArmoredTurtle/AFC-Klipper-Add-On.git}
AFC_COMMIT=${OC_AFC_COMMIT:-5ea84ea6fab75b9b49db090f309154d1e52272bb}
AFC=$DEMO_ROOT/usr/data/AFC-Klipper-Add-On
CONFIG=$DEMO_ROOT$OC_HOME/klipper/config/AFC
SHORT=$(echo "$AFC_COMMIT" | cut -c1-7)

die() { echo "ERROR $*"; exit 1; }

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would install AFC $SHORT into $AFC"
    exit 0
fi

if [ -f "$AFC/.commit" ] && [ "$(cat "$AFC/.commit")" = "$AFC_COMMIT" ] && [ -d "$AFC/extras" ]; then
    echo "STAGE AFC $SHORT already installed"
else
    echo "STAGE Downloading AFC $SHORT"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/oc-afc.XXXXXX") || die "cannot create work directory"
    trap 'rm -rf "$WORK"' EXIT
    # GitHub serves a commit by its full hash; the clone keeps no history
    git init -q "$WORK/afc" || die "cannot create $WORK/afc"
    (cd "$WORK/afc" && git fetch -q --depth 1 "$AFC_REPO" "$AFC_COMMIT" && git checkout -q FETCH_HEAD) ||
        die "cannot download AFC $SHORT"
    [ -d "$WORK/afc/extras" ] && [ -d "$WORK/afc/config/macros" ] || die "the AFC download is incomplete"
    rm -rf "$WORK/afc/.git"
    echo "$AFC_COMMIT" > "$WORK/afc/.commit"
    rm -rf "$AFC.old"
    [ ! -d "$AFC" ] || mv "$AFC" "$AFC.old"
    mv "$WORK/afc" "$AFC" || { [ ! -d "$AFC.old" ] || mv "$AFC.old" "$AFC"; die "cannot install AFC"; }
    rm -rf "$AFC.old"
    echo "STAGE AFC $SHORT installed to $AFC"
fi

# AFC_Macro_Vars.cfg includes macros/*.cfg; existing macros are kept
mkdir -p "$CONFIG/mcu"
if [ ! -d "$CONFIG/macros" ]; then
    cp -r "$AFC/config/macros" "$CONFIG/macros" || die "cannot copy AFC's macros to $CONFIG"
fi
sync
echo "STAGE AFC macros are in $CONFIG"
