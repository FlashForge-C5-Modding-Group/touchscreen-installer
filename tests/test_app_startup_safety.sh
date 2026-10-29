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
cp "$REPO_ROOT/payload-template/common/recover-app-startup.sh" "$FIXTURE_PAYLOAD/common/"
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
        "${5:-$FIXTURE_PAYLOAD}" "$1/backup" soc "${OC_TEST_WEB:-fluidd}" "${4:-yes}"
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

assert_no_startup_temporaries() {
    for temporary in "$1/usr/prog/app_startup.sh"* "$1/usr/prog/.app_startup.sh"*; do
        case "$temporary" in
            "$1/usr/prog/app_startup.sh"|"$1/usr/prog/app_startup.sh.opencreator-legacy") continue ;;
        esac
        [ ! -e "$temporary" ] && [ ! -L "$temporary" ] ||
            fail "recovery left temporary file $temporary"
    done
}

create_existing_install_state() {
    mkdir -p "$1/usr/data/opencreator"
    cat <<'EOF' > "$1/usr/data/opencreator/install.json"
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
}

create_recovery_cp_failure() {
    mkdir "$1/bin"
    cat <<'EOF' > "$1/bin/cp"
#!/bin/sh
source=
destination=
for argument in "$@"; do
    source=$destination
    destination=$argument
done
if [ "$source" = "$OC_DEMO_ROOT/usr/prog/app_startup.sh.opencreator-legacy" ]; then
    if [ "$OC_TEST_CP_FAILURE" = short-write ]; then
        printf '#!/bin/sh\n' > "$destination"
    fi
    exit 1
fi
exec "$OC_TEST_REAL_CP" "$@"
EOF
    chmod 755 "$1/bin/cp"
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

test_install_rejects_short_recovery_copy() {
    root=$TEST_DIR/t10
    prepare_stock_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    create_recovery_cp_failure "$root"
    real_cp=$(command -v cp)
    if output=$(PATH="$root/bin:$PATH" OC_TEST_REAL_CP="$real_cp" \
        OC_TEST_CP_FAILURE=short-write run_backend "$root" install 1 2>&1); then
        fail "install accepted a partial recovery copy: $output"
    fi
    [ ! -e "$root/usr/prog/app_startup.sh" ] ||
        fail "failed recovery published a partial live startup"
    [ ! -e "$root/usr/data/opencreator/install.json" ] ||
        fail "failed recovery wrote install state"
    [ ! -e "$root/usr/data/opencreator/install.json.tmp" ] ||
        fail "failed recovery left pending install state"
    if printf '%s\n' "$output" | grep -Fq 'STAGE OpenCreator installation complete'; then
        fail "failed recovery reported install success"
    fi
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "failed recovery damaged the legacy backup"
    assert_no_startup_temporaries "$root"
}

test_reconfigure_rejects_missing_recovery_copy() {
    root=$TEST_DIR/t11
    prepare_activation_root "$root"
    cp "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe"
    create_existing_install_state "$root"
    cp "$root/usr/data/opencreator/install.json" "$root/state.expected"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    create_recovery_cp_failure "$root"
    real_cp=$(command -v cp)
    if output=$(PATH="$root/bin:$PATH" OC_TEST_REAL_CP="$real_cp" \
        OC_TEST_CP_FAILURE=no-file run_backend "$root" reconfigure 1 no 2>&1); then
        fail "reconfigure accepted a failed recovery copy: $output"
    fi
    [ ! -e "$root/usr/prog/app_startup.sh" ] ||
        fail "failed reconfigure recovery published startup"
    cmp -s "$root/state.expected" "$root/usr/data/opencreator/install.json" ||
        fail "failed reconfigure recovery changed existing state"
    [ ! -e "$root/usr/data/opencreator/install.json.tmp" ] ||
        fail "failed reconfigure recovery left pending state"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "failed reconfigure recovery changed the legacy backup"
    assert_no_startup_temporaries "$root"
}

test_reconfigure_sanitizes_recovered_startup() {
    root=$TEST_DIR/t12
    prepare_activation_root "$root"
    cp "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe"
    cp "$root/usr/prog/PROGRAM/software/firmwareExe" "$root/firmware.expected"
    create_existing_install_state "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    # Same SoC/web UI, only yes -> no: no download or hardware payload steps.
    output=$(run_backend "$root" reconfigure 1 no 2>&1) ||
        fail "real reconfigure failed: $output"
    assert_sanitized_startup "$root"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "reconfigure changed the legacy backup"
    cmp -s "$root/firmware.expected" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "reconfigure replaced the current launcher"
    grep -Fxq '  "touchscreen": "no",' "$root/usr/data/opencreator/install.json" ||
        fail "reconfigure did not persist the requested configuration"
    assert_no_startup_temporaries "$root"
}

test_install_sanitizes_recovery_after_startup_and_source_deletion() {
    root=$TEST_DIR/t13
    prepare_stock_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh"
    cp "$root/usr/prog/app_startup.sh" "$root/expected"
    # Only this case gets a stage after real activation; do not mutate the
    # shared fixture used by the independent install and restore cases.
    cp -R "$FIXTURE_PAYLOAD" "$root/payload"
    cat <<'EOF' > "$root/payload/installers/soc/zz-delete-startup.sh"
#!/bin/sh
set -eu
cmp "$OC_TEST_LAUNCHER" "$OC_DEMO_ROOT/usr/prog/PROGRAM/software/firmwareExe"
rm "$OC_DEMO_ROOT/usr/prog/app_startup.sh"
rm "$OC_DEMO_ROOT/usr/data/opencreator/firmware/firmwareExe"
: > "$OC_DEMO_ROOT/late-stage.completed"
exit 0
EOF
    output=$(run_backend "$root" install 1 yes "$root/payload" 2>&1) ||
        fail "install failed after the successful late payload stage: $output"
    [ -f "$root/late-stage.completed" ] ||
        fail "install never completed the startup-deleting payload stage"
    assert_sanitized_startup "$root"
    [ -f "$root/usr/data/opencreator/install.json" ] ||
        fail "successful late-stage recovery did not write install state"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "late-stage recovery changed the legacy backup"
    cmp -s "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "late-stage recovery replaced the installed launcher"
    assert_no_startup_temporaries "$root"
}

test_check_preserves_stock_recovery_despite_stale_install_state() {
    root=$TEST_DIR/t14
    prepare_stock_root "$root"
    create_existing_install_state "$root"
    cp "$root/usr/data/opencreator/install.json" "$root/state.expected"
    cp "$root/usr/prog/PROGRAM/software/firmwareExe" "$root/firmware.expected"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    output=$(run_backend "$root" check 2>&1) ||
        fail "check failed with stock firmware and stale install state: $output"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh" ||
        fail "stale install state disabled legacy startup despite active stock firmware"
    [ -x "$root/usr/prog/app_startup.sh" ] ||
        fail "stock startup recovery is not executable"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "stock recovery changed the legacy backup"
    cmp -s "$root/firmware.expected" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "check replaced active stock firmware"
    cmp -s "$root/state.expected" "$root/usr/data/opencreator/install.json" ||
        fail "check changed the stale install record"
    assert_no_startup_temporaries "$root"
}

test_restore_recovers_stock_startup_when_startup_archive_is_absent() {
    root=$TEST_DIR/t15
    prepare_activation_root "$root"
    create_existing_install_state "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/startup.expected"
    cp "$root/usr/prog/PROGRAM/software/firmwareExe" "$root/firmware.expected"
    backup=$root/backup/opencreator-20260101T000000Z-1
    mkdir "$backup"
    printf 'usr/prog/app_startup.sh\n' > "$backup/absent.list"
    cp "$backup/absent.list" "$root/absent.expected"
    tar -C "$root" -cf "$backup/usr_prog_PROGRAM_software_firmwareExe.tar" \
        usr/prog/PROGRAM/software/firmwareExe
    cp "$backup/usr_prog_PROGRAM_software_firmwareExe.tar" "$root/archive.expected"
    cp "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe"
    output=$(run_backend "$root" restore 2>&1) ||
        fail "restore without a startup archive failed: $output"
    cmp -s "$root/startup.expected" "$root/usr/prog/app_startup.sh" ||
        fail "restore left legacy startup disabled after restoring stock firmware"
    [ -x "$root/usr/prog/app_startup.sh" ] ||
        fail "startup recovered for stock firmware is not executable"
    cmp -s "$root/firmware.expected" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "restore did not publish the archived stock firmware"
    cmp -s "$root/startup.expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "restore changed the raw legacy backup"
    cmp -s "$root/archive.expected" "$backup/usr_prog_PROGRAM_software_firmwareExe.tar" ||
        fail "restore changed the stock firmware archive"
    cmp -s "$root/absent.expected" "$backup/absent.list" ||
        fail "restore changed the older backup's absent list"
    [ ! -e "$root/usr/data/opencreator/install.json" ] ||
        fail "successful restore retained install state"
    assert_no_startup_temporaries "$root"
}

test_failed_restore_recovers_startup_for_current_opencreator_firmware() {
    root=$TEST_DIR/t16
    prepare_activation_root "$root"
    cp "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe"
    cp "$root/usr/prog/PROGRAM/software/firmwareExe" "$root/firmware.expected"
    create_existing_install_state "$root"
    cp "$root/usr/data/opencreator/install.json" "$root/state.expected"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/startup.expected"
    backup=$root/backup/opencreator-20260101T000000Z-1
    mkdir "$backup"
    printf 'usr/prog/app_startup.sh\n' > "$backup/absent.list"
    # The first restore archive is corrupt, so active firmware stays OC.
    printf 'corrupt firmware archive\n' > "$backup/usr_prog_PROGRAM_software_firmwareExe.tar.gz"
    cp "$backup/usr_prog_PROGRAM_software_firmwareExe.tar.gz" "$root/archive.expected"
    if output=$(run_backend "$root" restore 2>&1); then
        fail "restore accepted a corrupt first firmware archive: $output"
    fi
    assert_sanitized_startup "$root"
    cmp -s "$root/firmware.expected" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "failed restore changed the active OpenCreator launcher"
    cmp -s "$root/state.expected" "$root/usr/data/opencreator/install.json" ||
        fail "failed restore changed existing install state"
    cmp -s "$root/startup.expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "failed restore changed the raw legacy backup"
    cmp -s "$root/archive.expected" "$backup/usr_prog_PROGRAM_software_firmwareExe.tar.gz" ||
        fail "failed restore changed the corrupt firmware archive"
    assert_no_startup_temporaries "$root"
}

test_reconfigure_recovers_startup_deleted_by_web_step() {
    root=$TEST_DIR/t17
    prepare_activation_root "$root"
    cp "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe"
    create_existing_install_state "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh.opencreator-legacy"
    cp "$root/usr/prog/app_startup.sh.opencreator-legacy" "$root/expected"
    grep -Ev "$LEGACY_RE" "$root/usr/prog/app_startup.sh.opencreator-legacy" \
        > "$root/usr/prog/app_startup.sh"
    chmod 777 "$root/usr/prog/app_startup.sh"
    cp -R "$FIXTURE_PAYLOAD" "$root/payload"
    cat <<'EOF' > "$root/payload/installers/soc/20-install-web.sh"
#!/bin/sh
set -eu
rm "$OC_DEMO_ROOT/usr/prog/app_startup.sh"
: > "$OC_DEMO_ROOT/web-step.completed"
exit 0
EOF
    output=$(OC_TEST_WEB=mainsail run_backend "$root" reconfigure 1 yes "$root/payload" 2>&1) ||
        fail "web UI reconfigure failed after successful startup-deleting step: $output"
    [ -f "$root/web-step.completed" ] ||
        fail "reconfigure did not complete the requested web UI step"
    assert_sanitized_startup "$root"
    grep -Fxq '  "web_ui": "mainsail",' "$root/usr/data/opencreator/install.json" ||
        fail "reconfigure did not persist the requested web UI"
    cmp -s "$root/expected" "$root/usr/prog/app_startup.sh.opencreator-legacy" ||
        fail "web UI reconfigure changed the legacy backup"
    cmp -s "$OC_TEST_LAUNCHER" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
        fail "web UI reconfigure changed the current launcher"
    assert_no_startup_temporaries "$root"
}

test_install_rejects_startup_deleted_without_recovery_backup() {
    root=$TEST_DIR/t18
    prepare_stock_root "$root"
    create_legacy_startup "$root/usr/prog/app_startup.sh"
    cp -R "$FIXTURE_PAYLOAD" "$root/payload"
    cat <<'EOF' > "$root/payload/installers/soc/zz-delete-startup-and-backup.sh"
#!/bin/sh
set -eu
cmp "$OC_TEST_LAUNCHER" "$OC_DEMO_ROOT/usr/prog/PROGRAM/software/firmwareExe"
rm "$OC_DEMO_ROOT/usr/prog/app_startup.sh" \
    "$OC_DEMO_ROOT/usr/prog/app_startup.sh.opencreator-legacy"
: > "$OC_DEMO_ROOT/late-stage.completed"
exit 0
EOF
    if output=$(run_backend "$root" install 1 yes "$root/payload" 2>&1); then
        fail "install succeeded without startup or a recovery backup: $output"
    fi
    [ -f "$root/late-stage.completed" ] ||
        fail "install failed before the startup-and-backup deletion stage completed"
    [ ! -e "$root/usr/prog/app_startup.sh" ] ||
        fail "install published startup despite having no recovery source"
    [ ! -e "$root/usr/data/opencreator/install.json" ] ||
        fail "unrecoverable startup deletion wrote install state"
    [ ! -e "$root/usr/data/opencreator/install.json.tmp" ] ||
        fail "unrecoverable startup deletion left pending install state"
    if printf '%s\n' "$output" | grep -Fq 'STAGE OpenCreator installation complete'; then
        fail "unrecoverable startup deletion reported install success"
    fi
    assert_no_startup_temporaries "$root"
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
    test_update_leaves_sanitized_startup_unchanged \
    test_install_rejects_short_recovery_copy \
    test_reconfigure_rejects_missing_recovery_copy \
    test_reconfigure_sanitizes_recovered_startup \
    test_install_sanitizes_recovery_after_startup_and_source_deletion \
    test_check_preserves_stock_recovery_despite_stale_install_state \
    test_restore_recovers_stock_startup_when_startup_archive_is_absent \
    test_failed_restore_recovers_startup_for_current_opencreator_firmware \
    test_reconfigure_recovers_startup_deleted_by_web_step \
    test_install_rejects_startup_deleted_without_recovery_backup; do
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
