#!/bin/sh
# Standalone USB: FlashForge 2.0.0 firmware (firmwareExe, Klipper, app_startup) and
# MCU firmware (control 1.3.1), without the kernel. The stock boot runs this with
# MACHINE PID. See stock-2.0/README.md.

USB=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=/usr/prog/PROGRAM
WORK=/usr/data/stock-2.0
SOFTWARE=2.0.0
CONTROL=1.3.1
LOG=$USB/stock-2.0.log

exec >> "$LOG" 2>&1
echo "=== $(date) stock 2.0 for $1 $2"
fail() { echo "FAILED: $*"; rm -rf "$WORK"; sync; exit 1; }

MACHINE=${1:-$(sed -n 's/^MACHINE=//p' /usr/prog/app_startup.sh | head -n 1)}
PKG=$USB/stock-2.0/$MACHINE
[ -d "$PKG" ] || fail "no stock-2.0/$MACHINE on the drive"
[ "$(uname -m)" = mips ] || fail "not a Creator 5"

[ -f "$USB/start.img" ] && cat "$USB/start.img" > /dev/fb0

# Nothing is changed until everything is checked and unpacked.
cd "$PKG" && md5sum -c -s md5sum.list || fail "files on the drive are damaged; copy them again"
free_kb=$(df -kP /usr/data | awk 'NR == 2 { print $4 }')
[ "$free_kb" -ge 131072 ] || fail "/usr/data needs 128 MB free"
rm -rf "$WORK" && mkdir -p "$WORK" || fail "can't create $WORK"
for part in control software; do
    mkdir -p "$WORK/$part"
    tar -xf "$PKG/$part.tar" -C "$WORK/$part" || fail "can't unpack $part.tar"
    (cd "$WORK/$part" && md5sum -c -s md5sum.list) || fail "$part didn't unpack correctly"
done
S=$WORK/software
sync

echo "Installing software $SOFTWARE"
rm -rf /usr/prog/klipper/klippy/__pycache__ /usr/prog/klipper/klippy/*/__pycache__
mkdir -p /usr/prog/klipper/klippy
cp "$S"/klipper/klippy/*.py /usr/prog/klipper/klippy/ || fail "klippy"
for d in extras kinematics chelper; do
    mkdir -p "/usr/prog/klipper/klippy/$d"
    cp -a "$S/klipper/$d/." "/usr/prog/klipper/klippy/$d/" || fail "klippy/$d"
done
cp "$S/klipper/klipper_pri.sh" "$S/klipper/start.sh" /usr/prog/klipper/
cp -a "$S/klipper/config/." /usr/data/config/
cp "$S/8821cu.ko" /usr/prog/modules/8821cu.ko
cp "$S"/bin/* /usr/prog/bin/
cp "$S"/auth/* /usr/prog/etc/
sync
rm -rf "$RUN_DIR/software/$SOFTWARE"
mkdir -p "$RUN_DIR/software/$SOFTWARE"
cp "$S/firmwareExe.zip" "$S/firmwareExe" "$RUN_DIR/software/$SOFTWARE/"
cp "$S/firmwareExe" "$RUN_DIR/software/firmwareExe.new"
chmod 755 "$RUN_DIR/software/firmwareExe.new"
sync
mv "$RUN_DIR/software/firmwareExe.new" "$RUN_DIR/software/firmwareExe"
cp "$S/app_startup.sh" /usr/prog/app_startup.sh.new
chmod 755 /usr/prog/app_startup.sh.new
sync
mv /usr/prog/app_startup.sh.new /usr/prog/app_startup.sh
sync

# The stock boot flashes the boards from the newest control folder that has an
# Update marker, then reboots.
echo "Installing control $CONTROL (MCU firmware, flashed at the next boot)"
rm -rf "$RUN_DIR/control/$CONTROL"
mkdir -p "$RUN_DIR/control"
mv "$WORK/control" "$RUN_DIR/control/$CONTROL"
rm -f "$RUN_DIR/control/$CONTROL/md5sum.list"
touch "$RUN_DIR/control/$CONTROL/Update"
chmod 755 "$RUN_DIR/control/$CONTROL"/*
sync

[ ! -f /usr/data/opencreator/install.json ] || \
    mv /usr/data/opencreator/install.json /usr/data/opencreator/install.json.rolled-back
rm -rf "$WORK"
# Done once: the next boot flashes the MCUs instead of running this again.
mv "$USB/runFirmwareExe.sh" "$USB/runFirmwareExe.sh.done"
sync
echo "Done; rebooting to flash the MCUs"
[ -f "$USB/end.img" ] && cat "$USB/end.img" > /dev/fb0
sleep 2
umount "$USB" 2>/dev/null
reboot -f
