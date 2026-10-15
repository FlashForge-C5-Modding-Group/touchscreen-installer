#!/bin/sh
# Root login "opencreator" (password FlashForge2026) for SSH and the console,
# the same way OpenCreator Legacy's root enabler adds one: a uid 0 line in
# /etc/passwd. An existing opencreator entry (perhaps with a changed
# password) is left alone.
set -eu
DEMO_ROOT=${OC_DEMO_ROOT:-}
PASSWD=$DEMO_ROOT/etc/passwd
HOME_DIR=/usr/data/home/opencreator
# openssl passwd -1 -salt OpenCr26 FlashForge2026
ENTRY='opencreator:$1$OpenCr26$GkD/FnFEvnhuB.3isuW1y.:0:0:OpenCreator:'$HOME_DIR':/bin/sh'

die() { echo "ERROR $*"; exit 1; }

[ -f "$PASSWD" ] || die "$PASSWD not found"
mkdir -p "$DEMO_ROOT$HOME_DIR"
if grep -q '^opencreator:' "$PASSWD"; then
    echo "STAGE Root login opencreator already exists; left unchanged"
    exit 0
fi

echo "STAGE Adding the root login opencreator"
[ -f "$PASSWD.opencreator-bak" ] || cp -p "$PASSWD" "$PASSWD.opencreator-bak"
new=$PASSWD.opencreator-new
trap 'rm -f "$new"' EXIT
cp -p "$PASSWD" "$new"
# A file without a trailing newline would otherwise join the last line.
[ -z "$(tail -c 1 "$PASSWD")" ] || echo >> "$new"
echo "$ENTRY" >> "$new"
if ! grep -q '^root:' "$new" ||
    [ "$(grep -c '^opencreator:' "$new")" -ne 1 ] ||
    [ "$(grep -v '^opencreator:' "$new" | md5sum)" != \
      "$( { cat "$PASSWD"; [ -z "$(tail -c 1 "$PASSWD")" ] || echo; } | md5sum)" ]; then
    die "the new /etc/passwd failed its checks; left unchanged"
fi
sync
mv "$new" "$PASSWD"
sync
trap - EXIT
echo "STAGE Root login added: user opencreator, password FlashForge2026 (change it with passwd opencreator)"
