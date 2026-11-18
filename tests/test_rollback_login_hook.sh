#!/bin/sh
# A rollback to stock removes OpenCreator's login banner hook from /etc.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oc-test-rollback-login.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

root=$TEST_DIR/root
mkdir -p "$root/usr/prog/PROGRAM/software" "$root/usr/data/opencreator/startup/login" \
    "$root/etc/profile.d" "$TEST_DIR/backup"
printf '#!/bin/sh\nexit 0\n' > "$root/usr/prog/PROGRAM/software/firmwareExe"
printf '\177ELFstock firmware fixture\n' > "$root/usr/data/opencreator/firmwareExe.stock"
printf '{}\n' > "$root/usr/data/opencreator/install.json"
printf '# profile\n' > "$root/usr/data/opencreator/startup/login/profile.sh"
ln -s /usr/data/opencreator/startup/login/profile.sh "$root/etc/profile.d/opencreator.sh"
printf 'umask 022\n' > "$root/etc/profile.d/umask.sh"

OC_DEMO_ROOT=$root OC_STATE_DIR=$root/usr/data/opencreator \
    /bin/sh "$REPO_ROOT/scripts/install.sh" rollback "$REPO_ROOT/payload-template" \
    "$TEST_DIR/backup" soc fluidd yes > "$TEST_DIR/out" 2>&1 || { cat "$TEST_DIR/out" >&2; fail "rollback failed"; }

[ "$(dd if="$root/usr/prog/PROGRAM/software/firmwareExe" bs=1 skip=1 count=3 2>/dev/null)" = ELF ] ||
    fail "firmwareExe not restored"
[ ! -e "$root/etc/profile.d/opencreator.sh" ] && [ ! -L "$root/etc/profile.d/opencreator.sh" ] ||
    fail "login hook still in /etc/profile.d"
[ -f "$root/etc/profile.d/umask.sh" ] || fail "other profile.d files were touched"
[ -f "$root/usr/data/opencreator/install.json.rolled-back" ] || fail "install record not moved"

printf 'test_rollback_login_hook passed\n'
