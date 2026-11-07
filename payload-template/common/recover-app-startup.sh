#!/bin/sh
# Recover only missing startup scripts, unless activation requests rollback.
set -eu
DEMO_ROOT=${OC_DEMO_ROOT:-}
APP_STARTUP=$DEMO_ROOT/usr/prog/app_startup.sh
LEGACY=$APP_STARTUP.opencreator-legacy
OCDIR=$DEMO_ROOT/usr/data/opencreator
FIRMWARE_EXE=$DEMO_ROOT/usr/prog/PROGRAM/software/firmwareExe
INSTALL_STATE=${OC_STATE_DIR:-$OCDIR}/install.json
MODE=${1:-auto}
REPLACE=${2:-missing}
LEGACY_RE='^[[:space:]]*(sh[[:space:]]+)?/usr/prog/scripts/loop/loop\.sh[[:space:]]*&?[[:space:]]*$'
WEBCAM_RE='^[[:space:]]*(sh[[:space:]]*)?/usr/prog/mjpg-streamer/start_webcam\.sh[[:space:]]*&?[[:space:]]*$'
SLEEP_RE='^[[:space:]]*sleep[[:space:]]+2[[:space:]]*;?[[:space:]]*$'
MARK_RE='^: # OpenCreator: Legacy (LoopScript|webcam start) disabled'
# legacy_lines count|disable|drop FILE: the legacy LoopScript line and the
# webcam start line followed by "sleep 2", counted, swapped for no-ops, or left out.
legacy_lines() {
    LRE=$LEGACY_RE WRE=$WEBCAM_RE SRE=$SLEEP_RE awk -v mode="$1" '
        BEGIN { lre = ENVIRON["LRE"]; wre = ENVIRON["WRE"]; sre = ENVIRON["SRE"] }
        function keep(s) { if (mode != "count") print s }
        function off(s) { n++; if (mode == "disable") print s }
        {
            if (held) {
                held = 0
                if ($0 ~ sre) {
                    off(": # OpenCreator: Legacy webcam start disabled (was " t ")")
                    off(": # OpenCreator: Legacy webcam start disabled (was sleep 2)")
                    next
                }
                keep(w)
            }
            if ($0 ~ lre) { off(": # OpenCreator: Legacy LoopScript disabled (was /usr/prog/scripts/loop/loop.sh &)"); next }
            if ($0 ~ wre) { held = 1; w = $0; t = $0; sub(/^[[:space:]]+/, "", t); next }
            keep($0)
        }
        END { if (held) keep(w); if (mode == "count") print n + 0 }' "$2"
}

die() { echo "ERROR $*"; exit 1; }
# A read error is not evidence that the legacy launcher is absent.
has_legacy_line() {
    count=$(legacy_lines count "$1") || die "cannot inspect the recovered legacy launcher"
    [ "$count" -gt 0 ]
}
case "$MODE" in auto|opencreator) ;; *) die "invalid startup recovery mode" ;; esac
case "$REPLACE" in missing|replace) ;; *) die "invalid startup recovery operation" ;; esac
if [ "$REPLACE" = missing ] && [ -f "$APP_STARTUP" ]; then exit 0; fi
if [ ! -f "$LEGACY" ]; then
    [ "$REPLACE" != replace ] || die "legacy startup backup is missing"
    exit 0
fi
[ ! -d "$APP_STARTUP" ] || die "startup path is a directory: $APP_STARTUP"

# A stock ELF launcher takes precedence over a stale install record during
# restore. Exact launcher equality also detects fresh activation before the
# install record is written; the record covers updates replacing the source.
if [ "$MODE" = auto ]; then
    magic=
    if [ -f "$FIRMWARE_EXE" ]; then
        magic=$(dd if="$FIRMWARE_EXE" bs=1 skip=1 count=3 2>/dev/null) ||
            die "cannot inspect the active firmware launcher"
    fi
    if [ "$magic" != ELF ] &&
        { [ -f "$INSTALL_STATE" ] || cmp -s "$FIRMWARE_EXE" "$OCDIR/firmware/firmwareExe"; }; then
        MODE=opencreator
    fi
fi

echo "STAGE Recovering app_startup.sh from opencreator-legacy backup"
candidate=$(mktemp "$APP_STARTUP.opencreator-recover.XXXXXX") ||
    die "cannot create temporary startup script"
trap 'rm -f "$candidate"' EXIT
# Explicit checks are required even when callers run recovery conditionally.
cp -p "$LEGACY" "$candidate" || die "cannot copy the legacy startup backup"
cmp -s "$LEGACY" "$candidate" || die "startup recovery copy differs from its backup"
if [ "$MODE" = opencreator ] && has_legacy_line "$candidate"; then
    legacy_lines disable "$LEGACY" > "$candidate" || die "cannot disable the recovered legacy launcher"
    if has_legacy_line "$candidate"; then
        die "recovered startup still enables the legacy launcher"
    fi
fi
sh -n "$candidate" || die "recovered startup has invalid shell syntax"
grep -q 'runFirmwareExe.sh' "$candidate" || die "recovered startup is missing the USB update hook"
grep -q 'PROGRAM/software/firmwareExe' "$candidate" || die "recovered startup is missing the firmware launch"
chmod 777 "$candidate" || die "cannot make recovered startup executable"
sync || die "cannot sync recovered startup before publication"
mv "$candidate" "$APP_STARTUP" || die "cannot publish recovered startup"
sync || die "cannot sync recovered startup after publication"
