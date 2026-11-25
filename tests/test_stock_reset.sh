#!/bin/sh
# Full rollback (stock-reset) with the printer's BusyBox, whose od has no
# -A/-t/-N: it must still restore the stock logo, firmwareExe and control
# package (issue #17: "the installer has no stock boot logo").
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oc-test-stock-reset.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

root=$TEST_DIR/root
files=$TEST_DIR/archive
bin=$TEST_DIR/bin
mkdir -p "$root/usr/prog/PROGRAM/software" "$root/usr/data/opencreator" \
    "$files" "$bin" "$TEST_DIR/backup"
cat > "$root/usr/prog/app_startup.sh" <<'EOF'
#!/bin/sh
MACHINE=Creator5Pro
PID=0029
[ -f /usr/prog/PROGRAM/control/*/Update ] && echo update
EOF
printf '#!/bin/sh\nexit 0\n' > "$root/usr/prog/PROGRAM/software/firmwareExe"
printf '\177ELFstock firmware fixture\n' > "$root/usr/data/opencreator/firmwareExe.stock"
printf 'OpenCreator logo\n' > "$root/usr/prog/logo.jpeg"
printf '{}\n' > "$root/usr/data/opencreator/install.json"

# The stock archive's control folder, served by the curl stub.
for f in run.sh IAPCommand ISPCommand eBoard.hex heaterBoard.hex levelBoard.hex mainBoardGD.hex; do
    printf 'stock %s\n' "$f" > "$files/$f"
done
blob_sha() {
    { printf 'blob %s\0' "$(wc -c < "$1" | tr -d ' ')"; cat "$1"; } | sha1sum | cut -d' ' -f1
}
{
    printf '['
    sep=
    for f in "$files"/*; do
        n=${f##*/}
        printf '%s{"name": "%s", "sha": "%s", "size": %s, "download_url": "https://files.test/%s"}' \
            "$sep" "$n" "$(blob_sha "$f")" "$(wc -c < "$f" | tr -d ' ')" "$n"
        sep=,
    done
    printf ']\n'
} > "$TEST_DIR/control.json"

cat > "$bin/curl" <<EOF
#!/bin/sh
out=
while [ \$# -gt 1 ]; do
    case "\$1" in
        -o) out=\$2; shift 2 ;;
        -H) shift 2 ;;
        *) shift ;;
    esac
done
case "\$1" in
    */software/md5sum.list) body="0123  ./control/1.2.3/run.sh" ;;
    */contents/control\?*) body=\$(cat "$TEST_DIR/control.json") ;;
    https://files.test/*) body=\$(cat "$files/\${1##*/}") ;;
    *) echo "curl stub: unexpected \$1" >&2; exit 22 ;;
esac
if [ -n "\$out" ]; then printf '%s\n' "\$body" > "\$out"; else printf '%s\n' "\$body"; fi
EOF
# The printer's BusyBox od
printf '#!/bin/sh\necho "od: invalid option -- '"'"'A'"'"'" >&2\nexit 1\n' > "$bin/od"
chmod 755 "$bin/curl" "$bin/od"

PATH=$bin:$PATH OC_DEMO_ROOT=$root OC_STATE_DIR=$root/usr/data/opencreator \
    /bin/sh "$REPO_ROOT/scripts/install.sh" stock-reset "$REPO_ROOT/payload-template" \
    "$TEST_DIR/backup" soc fluidd yes > "$TEST_DIR/out" 2>&1 ||
    { cat "$TEST_DIR/out" >&2; fail "stock-reset failed"; }

cmp -s "$REPO_ROOT/payload-template/common/stock-logo.jpeg" "$root/usr/prog/logo.jpeg" ||
    fail "stock boot logo not restored"
cmp -s "$root/usr/data/opencreator/firmwareExe.stock" "$root/usr/prog/PROGRAM/software/firmwareExe" ||
    fail "stock firmwareExe not restored"
for f in "$files"/*; do
    cmp -s "$f" "$root/usr/prog/PROGRAM/control/1.2.3/${f##*/}" || fail "control/${f##*/} not staged"
done
[ -f "$root/usr/prog/PROGRAM/control/1.2.3/Update" ] || fail "control package not flagged for update"
[ -f "$root/usr/data/opencreator/install.json.rolled-back" ] || fail "install record not moved"

printf 'test_stock_reset passed\n'
