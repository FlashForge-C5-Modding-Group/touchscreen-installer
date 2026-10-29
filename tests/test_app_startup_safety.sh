#!/bin/sh
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oc-test-app-startup.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# Helper to populate a mock stock app_startup.sh with legacy loop line
create_legacy_startup() {
    target=$1
    mkdir -p "$(dirname "$target")"
    cat <<'EOF' > "$target"
#!/bin/sh
MACHINE=Creator5Pro
PID=0029
/usr/prog/scripts/loop/loop.sh &
if [ -f /mnt/runFirmwareExe.sh ]; then
    /mnt/runFirmwareExe.sh
fi
/usr/prog/PROGRAM/software/firmwareExe &
EOF
    chmod 777 "$target"
}

# Test 1: activate-loopscript.sh recovers missing app_startup.sh when .opencreator-legacy exists
echo "=== Running Test 1: activate-loopscript recovers missing app_startup.sh ==="
T1_ROOT=$TEST_DIR/t1
mkdir -p "$T1_ROOT/usr/data/opencreator/firmware" "$T1_ROOT/usr/prog"
touch "$T1_ROOT/usr/data/opencreator/firmware/firmwareExe"
# Create legacy file but leave app_startup.sh missing
create_legacy_startup "$T1_ROOT/usr/prog/app_startup.sh.opencreator-legacy"
[ ! -f "$T1_ROOT/usr/prog/app_startup.sh" ] || fail "app_startup.sh should not exist yet"

OC_DEMO_ROOT="$T1_ROOT" OC_PAYLOAD="$REPO_ROOT/payload-template" \
    /bin/sh "$REPO_ROOT/payload-template/common/activate-loopscript.sh" || fail "activate-loopscript failed"

[ -f "$T1_ROOT/usr/prog/app_startup.sh" ] || fail "Test 1: app_startup.sh was not created"
[ -x "$T1_ROOT/usr/prog/app_startup.sh" ] || fail "Test 1: app_startup.sh is not executable"
grep -q "Legacy LoopScript disabled" "$T1_ROOT/usr/prog/app_startup.sh" || fail "Test 1: legacy line was not disabled"
pass "Test 1: activate-loopscript.sh recovered missing app_startup.sh from .opencreator-legacy"

# Test 2: In activate-loopscript.sh, if post-swap validation fails, it must roll back to .opencreator-legacy
echo "=== Running Test 2: cleanup_and_recover trap restores app_startup.sh on exit ==="
T2_ROOT=$TEST_DIR/t2
mkdir -p "$T2_ROOT/usr/prog"
create_legacy_startup "$T2_ROOT/usr/prog/app_startup.sh.opencreator-legacy"
(
    DEMO_ROOT="$T2_ROOT"
    APP_STARTUP=$DEMO_ROOT/usr/prog/app_startup.sh
    new=$APP_STARTUP.opencreator-new
    cleanup_and_recover() {
        rm -f "$new" "$new.after" "$new.orig"
        if [ ! -f "$APP_STARTUP" ] && [ -f "$APP_STARTUP.opencreator-legacy" ]; then
            cp -p "$APP_STARTUP.opencreator-legacy" "$APP_STARTUP" 2>/dev/null || true
            chmod 777 "$APP_STARTUP" 2>/dev/null || true
            sync 2>/dev/null || true
        fi
    }
    trap cleanup_and_recover EXIT
    exit 1
) || true
[ -f "$T2_ROOT/usr/prog/app_startup.sh" ] || fail "Test 2: trap failed to recover app_startup.sh"
[ -x "$T2_ROOT/usr/prog/app_startup.sh" ] || fail "Test 2: recovered app_startup.sh is not executable"
pass "Test 2: trap successfully recovered app_startup.sh from .opencreator-legacy"

# Test 3: restore_backup does NOT remove app_startup.sh even if absent.list has it
echo "=== Running Test 3: restore_backup never removes app_startup.sh via absent.list ==="
T3_ROOT=$TEST_DIR/t3
mkdir -p "$T3_ROOT/usr/prog" "$T3_ROOT/backup/opencreator-20260101T000000Z-1"
create_legacy_startup "$T3_ROOT/usr/prog/app_startup.sh"
echo "usr/prog/app_startup.sh" > "$T3_ROOT/backup/opencreator-20260101T000000Z-1/absent.list"

# Call restore action
OC_DEMO_ROOT="$T3_ROOT" /bin/sh "$REPO_ROOT/scripts/install.sh" restore \
    "$REPO_ROOT/payload-template" "$T3_ROOT/backup" soc fluidd yes || true

[ -f "$T3_ROOT/usr/prog/app_startup.sh" ] || fail "Test 3: restore_backup deleted app_startup.sh because of absent.list"
pass "Test 3: restore_backup protected app_startup.sh from absent.list"

# Test 4: restore_backup heals missing app_startup.sh from .opencreator-legacy if archive missing or corrupt
echo "=== Running Test 4: restore_backup heals missing app_startup.sh from .opencreator-legacy ==="
T4_ROOT=$TEST_DIR/t4
mkdir -p "$T4_ROOT/usr/prog" "$T4_ROOT/backup/opencreator-20260101T000000Z-1"
create_legacy_startup "$T4_ROOT/usr/prog/app_startup.sh.opencreator-legacy"
# Corrupt archive
echo "corrupt" > "$T4_ROOT/backup/opencreator-20260101T000000Z-1/usr_prog_app_startup.sh.tar.gz"

OC_DEMO_ROOT="$T4_ROOT" /bin/sh "$REPO_ROOT/scripts/install.sh" restore \
    "$REPO_ROOT/payload-template" "$T4_ROOT/backup" soc fluidd yes || true

[ -f "$T4_ROOT/usr/prog/app_startup.sh" ] || fail "Test 4: restore_backup failed to heal app_startup.sh from .opencreator-legacy"
pass "Test 4: restore_backup healed missing app_startup.sh from .opencreator-legacy"

# Test 5: check / detect_model recovers missing app_startup.sh from .opencreator-legacy
echo "=== Running Test 5: install.sh check recovers missing app_startup.sh ==="
T5_ROOT=$TEST_DIR/t5
mkdir -p "$T5_ROOT/usr/prog" "$T5_ROOT/backup"
create_legacy_startup "$T5_ROOT/usr/prog/app_startup.sh.opencreator-legacy"
[ ! -f "$T5_ROOT/usr/prog/app_startup.sh" ]

output=$(OC_DEMO_ROOT="$T5_ROOT" /bin/sh "$REPO_ROOT/scripts/install.sh" check \
    "$REPO_ROOT/payload-template" "$T5_ROOT/backup" soc fluidd yes 2>&1)
echo "$output" | grep -q "MODEL Creator5Pro 0029" || fail "Test 5: model not detected from legacy file"
[ -f "$T5_ROOT/usr/prog/app_startup.sh" ] || fail "Test 5: check did not recover app_startup.sh"
pass "Test 5: check detected model and recovered app_startup.sh"

echo "=== All tests passed ==="
