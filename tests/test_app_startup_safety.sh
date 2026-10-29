#!/bin/sh
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oc-test-app-startup.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Exercise the real backend and activation, replacing only the payload steps
# that would download software or operate on printer hardware.
FIXTURE_PAYLOAD=$TEST_DIR/payload
mkdir -p "$FIXTURE_PAYLOAD/installers/soc" "$FIXTURE_PAYLOAD/common"
cp "$REPO_ROOT/payload-template/common/logo.jpeg" "$FIXTURE_PAYLOAD/common/logo.jpeg"
OC_TEST_ACTIVATION=$REPO_ROOT/payload-template/common/activate-loopscript.sh
OC_TEST_LAUNCHER=$TEST_DIR/firmwareExe.launcher
export OC_TEST_ACTIVATION OC_TEST_LAUNCHER
printf '#!/bin/sh\nexit 0\n' > "$OC_TEST_LAUNCHER"
cat <<'EOF' > "$FIXTURE_PAYLOAD/installers/soc/99-activate.sh"
#!/bin/sh
set -eu
# The installer must have recovered startup before handing off to activation.
[ -f "$OC_DEMO_ROOT/usr/prog/app_startup.sh" ]
mkdir -p "$OC_DEMO_ROOT/usr/data/opencreator/firmware"
cp "$OC_TEST_LAUNCHER" "$OC_DEMO_ROOT/usr/data/opencreator/firmware/firmwareExe"
exec /bin/sh "$OC_TEST_ACTIVATION"
EOF

LEGACY_RE='^[[:space:]]*(sh[[:space:]]+)?/usr/prog/scripts/loop/loop\.sh[[:space:]]*&?[[:space:]]*$'

create_legacy_startup() {
    mkdir -p "$(dirname "$1")"
    # Creator5/0028 deliberately differs from the installer's demo fallback.
    cat <<'EOF' > "$1"
#!/bin/sh
MACHINE=Creator5
PID=0028
/usr/prog/scripts/loop/loop.sh &
if [ -f /mnt/runFirmwareExe.sh ]; then
    /mnt/runFirmwareExe.sh
fi
/usr/prog/PROGRAM/software/firmwareExe &
EOF
    chmod 777 "$1"
}

prepare_stock_root() {
    mkdir -p "$1/usr/prog/PROGRAM/software" "$1/backup"
    printf '\177ELFstock firmware fixture\n' > "$1/usr/prog/PROGRAM/software/firmwareExe"
    chmod 755 "$1/usr/prog/PROGRAM/software/firmwareExe"
    printf 'stock logo fixture\n' > "$1/usr/prog/logo.jpeg"
}

prepare_activation_root() {
    prepare_stock_root "$1"
    mkdir -p "$1/usr/data/opencreator/firmware"
    cp "$OC_TEST_LAUNCHER" "$1/usr/data/opencreator/firmware/firmwareExe"
}

run_backend() {
    OC_DEMO_ROOT="$1" OC_STATE_DIR="$1/usr/data/opencreator" \
        OC_MACHINE= OC_PID= OC_KERNEL_PACKAGE=2.0.7 \
        OC_NEW_INSTALL_MIN_KB=0 OC_MIN_FREE_KB=0 OC_SKIP_BACKUP="${3:-0}" \
        /bin/sh "$REPO_ROOT/scripts/install.sh" "$2" \
        "$FIXTURE_PAYLOAD" "$1/backup" soc fluidd yes
}

assert_sanitized_startup() {
    [ -f "$1/usr/prog/app_startup.sh" ] || fail "startup is missing"
    [ -x "$1/usr/prog/app_startup.sh" ] || fail "startup is not executable"
    /bin/sh -n "$1/usr/prog/app_startup.sh" || fail "startup has invalid shell syntax"
    if grep -Eq "$LEGACY_RE" "$1/usr/prog/app_startup.sh"; then
        fail "startup still launches the legacy LoopScript"
    fi
    grep -Fxq 'if [ -f /mnt/runFirmwareExe.sh ]; then' "$1/usr/prog/app_startup.sh" ||
        fail "USB update check was removed"
    grep -Fxq '    /mnt/runFirmwareExe.sh' "$1/usr/prog/app_startup.sh" ||
        fail "USB update hook was removed"
    grep -Fxq '/usr/prog/PROGRAM/software/firmwareExe &' "$1/usr/prog/app_startup.sh" ||
        fail "firmware boot hook was removed"
}

test_activation_recovers_missing_startup() {
    root=$TEST_DIR/t1
    prepare_activation_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    OC_DEMO_ROOT="$root" OC_PAYLOAD="$FIXTURE_PAYLOAD" OC_UPDATE=0 \
        /bin/sh "$OC_TEST_ACTIVATION"
    assert_sanitized_startup "$root"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "activation changed the legacy backup"
}

test_activation_swap_failure_recovers_and_cleans_up() {
    root=$TEST_DIR/t2
    prepare_activation_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh"
    cp "$root/usr/prog/app_startup.sh" "$root/expected"
    cp "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/PROGRAM/software/firmwareExe" "$root/firmware.expected"
    mkdir "$root/bin"
    cat <<'EOF' > "$root/bin/mv"
#!/bin/sh
if [ "$#" -eq 2 ] &&
    [ "$1" = "$OC_DEMO_ROOT/usr/prog/app_startup.sh.opencreator-new" ] &&
    [ "$2" = "$OC_DEMO_ROOT/usr/prog/app_startup.sh" ]; then
    rm -f "$2"
    echo "INJECTED startup swap failure" >&2
    exit 73
fi
exec "$OC_TEST_REAL_MV" "$@"
EOF
    chmod 755 "$root/bin/mv"
    real_mv=$(command -v mv)
    if output=$(PATH="$root/bin:$PATH" OC_TEST_REAL_MV="$real_mv" \
        OC_DEMO_ROOT="$root" OC_PAYLOAD="$FIXTURE_PAYLOAD" OC_UPDATE=0 \
        /bin/sh "$OC_TEST_ACTIVATION" 2>&1); then
        fail "activation succeeded despite the failed startup swap"
    fi
    printf '%s\n' "$output" | grep -Fxq 'INJECTED startup swap failure' ||
        fail "activation failed before the injected startup swap: $output"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh" ||
        fail "the real activation trap did not recover startup byte-for-byte"
    [ -x "$root/usr/prog/app_startup.sh" ] || fail "recovered startup is not executable"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "failed activation changed the legacy backup"
    for temporary in "$root/usr/prog/app_startup.sh.opencreator-new" \
        "$root/usr/prog/app_startup.sh.opencreator-new.after" \
        "$root/usr/prog/app_startup.sh.opencreator-new.orig"; do
        [ ! -e "$temporary" ] || fail "activation left temporary file $temporary"
    done
    cmp -s "$root/firmware.expected" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "activation replaced firmware after failing to swap startup"
}

test_restore_ignores_startup_in_absent_list() {
    root=$TEST_DIR/t3
    prepare_stock_root "$root"
    backup=$root/backup/opencreator-20260101T000000Z-1
    mkdir "$backup"
    create_legacy_startup "$root/usr/prog/app_startup.sh"
    cp "$root/usr/prog/app_startup.sh" "$root/expected"
    printf 'usr/prog/app_startup.sh\n' > "$backup/absent.list"
    output=$(run_backend "$root" restore 2>&1) || fail "restore failed unexpectedly: $output"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh" ||
        fail "restore removed or changed startup because of absent.list"
}

test_damaged_archive_still_recovers_startup() {
    root=$TEST_DIR/t4
    prepare_stock_root "$root"
    backup=$root/backup/opencreator-20260101T000000Z-1
    mkdir "$backup"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    : > "$backup/absent.list"
    printf 'corrupt\n' > "$backup/usr_prog_app_startup.sh.tar.gz"
    if output=$(run_backend "$root" restore 2>&1); then
        fail "restore accepted a damaged archive"
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || fail "unexpected restore exit status ($status): $output"
    printf '%s\n' "$output" |
        grep -Fxq 'ERROR backup archive damaged: usr_prog_app_startup.sh.tar.gz' ||
        fail "restore failed for a reason other than the damaged archive: $output"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh" ||
        fail "restore did not heal startup byte-for-byte before rejecting the archive"
    [ -x "$root/usr/prog/app_startup.sh" ] || fail "healed startup is not executable"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "restore changed the legacy backup"
}

test_check_recovers_model_from_legacy() {
    root=$TEST_DIR/t5
    prepare_stock_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    output=$(run_backend "$root" check 2>&1) || fail "check failed unexpectedly: $output"
    printf '%s\n' "$output" | grep -Fxq 'MODEL Creator5 0028' ||
        fail "check used the demo fallback instead of the recovered model: $output"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh" ||
        fail "model detection did not recover startup byte-for-byte"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "model detection changed the legacy backup"
}

test_install_backup_restore_round_trip() {
    root=$TEST_DIR/t6
    prepare_stock_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh"
    cp "$root/usr/prog/app_startup.sh" "$root/startup.expected"
    cp "$root/usr/prog/PROGRAM/software/firmwareExe" "$root/firmware.expected"
    cp "$root/usr/prog/logo.jpeg" "$root/logo.expected"
    output=$(run_backend "$root" install 2>&1) || fail "real install failed: $output"
    assert_sanitized_startup "$root"
    cmp -s "$root/startup.expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "install changed the original legacy startup backup"
    cmp -s "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "activation did not install the launcher"
    set -- "$root"/backup/opencreator-*
    [ "$#" -eq 1 ] && [ -d "$1" ] || fail "install did not create exactly one backup"
    backup=$1
    [ -f "$backup/absent.list" ] || fail "backup is missing absent.list"
    grep -Fxq "  \"backup\": \"$backup\"," "$root/usr/data/opencreator/install.json" ||
        fail "install record points outside its actual backup directory"
    mkdir "$root/extracted"
    for member in usr_prog_app_startup.sh usr_prog_PROGRAM_software_firmwareExe usr_prog_logo.jpeg; do
        archive=$backup/$member.tar.gz
        [ -f "$archive" ] || fail "backup archive missing: $archive"
        gunzip -t "$archive" || fail "backup archive is damaged: $archive"
        gunzip -c "$archive" | tar -C "$root/extracted" -xf - ||
            fail "backup archive cannot be extracted: $archive"
    done
    cmp -s "$root/startup.expected" "$root/extracted/usr/prog/app_startup.sh" ||
        fail "backup does not contain the original startup"
    cmp -s "$root/firmware.expected" "$root/extracted/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "backup does not contain the stock firmware"
    cmp -s "$root/logo.expected" "$root/extracted/usr/prog/logo.jpeg" ||
        fail "backup does not contain the stock logo"
    output=$(run_backend "$root" restore 2>&1) || fail "round-trip restore failed: $output"
    cmp -s "$root/startup.expected" "$root/usr/prog/app_startup.sh" ||
        fail "restore did not restore stock startup byte-for-byte"
    [ -x "$root/usr/prog/app_startup.sh" ] || fail "restored startup is not executable"
    cmp -s "$root/firmware.expected" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "restore did not restore stock firmware byte-for-byte"
    [ -x "$root/usr/prog/PROGRAM/software/firmwareExe" ] || fail "restored firmware is not executable"
    cmp -s "$root/logo.expected" "$root/usr/prog/logo.jpeg" ||
        fail "restore did not restore the stock logo"
    cmp -s "$root/startup.expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "round-trip restore changed the legacy backup"
    [ ! -e "$root/usr/data/opencreator/install.json" ] || fail "restore retained install state"
}

test_update_activation_sanitizes_recovered_startup() {
    root=$TEST_DIR/t7
    prepare_activation_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    OC_DEMO_ROOT="$root" OC_PAYLOAD="$FIXTURE_PAYLOAD" OC_UPDATE=1 \
        /bin/sh "$OC_TEST_ACTIVATION"
    assert_sanitized_startup "$root"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "update activation changed the legacy backup"
}

test_update_install_sanitizes_startup_recovered_by_detection() {
    root=$TEST_DIR/t8
    prepare_stock_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    mkdir -p "$root/usr/data/opencreator"
    cat <<'EOF' > "$root/usr/data/opencreator/install.json"
{
  "installer_version": "0.0.5.0",
  "machine": "Creator5",
  "pid": "0028",
  "mode": "soc",
  "web_ui": "fluidd",
  "touchscreen": "yes",
  "backup": "none",
  "installed_utc": "2026-01-01T00:00:00Z"
}
EOF
    # Existing-install updates use the no-backup path, isolating this recovery
    # from the independent fresh-install backup regression above.
    output=$(run_backend "$root" install 1 2>&1) || fail "real update install failed: $output"
    assert_sanitized_startup "$root"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "update install changed the legacy backup"
}

test_update_leaves_sanitized_startup_unchanged() {
    root=$TEST_DIR/t9
    prepare_activation_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/legacy.expected"
    cat <<'EOF' > "$root/usr/prog/app_startup.sh"
#!/bin/sh
MACHINE=Creator5
PID=0028
: # Legacy startup already disabled by the previous install
# Preserve this user's boot customization.
if [ -f /mnt/runFirmwareExe.sh ]; then
    /mnt/runFirmwareExe.sh
fi
/usr/prog/PROGRAM/software/firmwareExe &
EOF
    chmod 777 "$root/usr/prog/app_startup.sh"
    cp "$root/usr/prog/app_startup.sh" "$root/expected"
    OC_DEMO_ROOT="$root" OC_PAYLOAD="$FIXTURE_PAYLOAD" OC_UPDATE=1 \
        /bin/sh "$OC_TEST_ACTIVATION"
    assert_sanitized_startup "$root"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh" ||
        fail "update changed an already-sanitized startup"
    cmp -s "$root/legacy.expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "update changed the existing legacy backup"
}

# Do not invoke test functions in an if/|| condition: POSIX shells would
# disable errexit inside them and hide unexpected fixture/command failures.
# Each independent case runs with errexit in its own subshell instead.
failures=0
for test_case in \
    test_activation_recovers_missing_startup \
    test_activation_swap_failure_recovers_and_cleans_up \
    test_restore_ignores_startup_in_absent_list \
    test_damaged_archive_still_recovers_startup \
    test_check_recovers_model_from_legacy \
    test_install_backup_restore_round_trip \
    test_update_activation_sanitizes_recovered_startup \
    test_update_install_sanitizes_startup_recovered_by_detection \
    test_update_leaves_sanitized_startup_unchanged; do
    printf '=== Running %s ===\n' "$test_case"
    set +e
    (
        set -e
        "$test_case"
    )
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        printf 'PASS: %s\n' "$test_case"
    else
        printf 'FAIL: %s (exit %s)\n' "$test_case" "$status" >&2
        failures=$((failures + 1))
    fi
done
[ "$failures" -eq 0 ] || fail "$failures independent test case(s) failed"
printf '=== All tests passed ===\n'
