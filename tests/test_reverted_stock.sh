#!/bin/sh
# check reports REVERTED only for a stock firmwareExe where OpenCreator has been.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oc-test-reverted.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

STATE='{
  "installer_version": "0.0.5",
  "machine": "Creator5Pro",
  "pid": "0029",
  "kernel_package": "2.0.7",
  "mode": "soc",
  "web_ui": "fluidd",
  "touchscreen": "yes",
  "backup": "",
  "installed_at": "2026-01-01T00:00:00Z"
}'

# new_root NAME FIRMWARE: FIRMWARE is elf or script
new_root() {
    root=$TEST_DIR/$1
    mkdir -p "$root/usr/prog/PROGRAM/software" "$root/usr/prog/PROGRAM/kernel/2.0.7" \
        "$root/usr/data/opencreator" "$TEST_DIR/backup"
    if [ "$2" = elf ]; then
        printf '\177ELFstock firmware fixture\n' > "$root/usr/prog/PROGRAM/software/firmwareExe"
    else
        printf '#!/bin/sh\nexit 0\n' > "$root/usr/prog/PROGRAM/software/firmwareExe"
    fi
}

check() {
    OC_DEMO_ROOT=$root OC_STATE_DIR=$root/usr/data/opencreator OC_MACHINE= OC_PID= \
        OC_KERNEL_PACKAGE=2.0.7 OC_NEW_INSTALL_MIN_KB=0 OC_MIN_FREE_KB=0 \
        /bin/sh "$REPO_ROOT/scripts/install.sh" check "$REPO_ROOT/payload-template" \
        "$TEST_DIR/backup" soc fluidd yes 2>&1 || :
}

new_root stock_recorded elf
printf '%s\n' "$STATE" > "$root/usr/data/opencreator/install.json"
out=$(check)
printf '%s\n' "$out" | grep -qx REVERTED || fail "stock firmwareExe with an install record: no REVERTED"
printf '%s\n' "$out" | grep -q '^WARN .*will reinstall OpenCreator' || fail "no reinstall notice"
printf '%s\n' "$out" | grep -n '^PREVIOUS \|^REVERTED$' | head -n 1 | grep -q PREVIOUS ||
    fail "REVERTED must come after PREVIOUS"

new_root stock_rolled_back elf
printf '%s\n' "$STATE" > "$root/usr/data/opencreator/install.json.rolled-back"
check | grep -qx REVERTED || fail "rolled back printer: no REVERTED"

new_root stock_saved elf
printf 'stock\n' > "$root/usr/data/opencreator/firmwareExe.stock"
check | grep -qx REVERTED || fail "saved stock firmwareExe: no REVERTED"

new_root never_installed elf
if check | grep -q 'REVERTED\|will reinstall'; then fail "never installed printer: REVERTED"; fi

new_root running script
printf '%s\n' "$STATE" > "$root/usr/data/opencreator/install.json"
if check | grep -q 'REVERTED\|will reinstall'; then fail "launcher in place: REVERTED"; fi

printf 'test_reverted_stock passed\n'
