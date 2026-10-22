#!/bin/sh
# Run by the stock /usr/prog/app_startup.sh from the root of a FAT USB drive
# mounted at /mnt, with MACHINE and PID as arguments. Exiting 0 stops the
# boot here; any other exit code lets the normal boot continue.
USB=/mnt
OC=$USB/opencreator
BACKUPS=$OC/backups
WPA_CONF=/usr/prog/wifi/wpa_supplicant.conf

[ -d "$OC" ] || exit 1
exec >> "$OC/runFirmwareExe.log" 2>&1
echo "=== $(date) $*"

[ "$(uname -m)" = mips ] || { echo "not a Creator 5"; exit 1; }

# Legacy NaN and Entware first: anything that runs a shell needs them when
# the root shell is Entware's (for example /opt/bin/bash).
case "$(ls /usr/prog/PROGRAM/kernel/ 2>/dev/null | head -n 1)" in
    2.0.1|2.0.2|2.0.3|2.0.4|2.0.5|2.0.6) busybox devmem 0x00a130d1 8 1 ;;
    2.0.7) busybox devmem 0x00B330D1 8 1 ;;
    2.0.8) busybox devmem 0x00B030D1 8 1 ;;
    *) echo "unknown kernel package; legacy NaN not enabled" ;;
esac
if [ ! -x /opt/bin/opkg ] && [ -d /usr/data/bin/opt ] && ! grep -q ' /opt ' /proc/mounts; then
    mount --bind /usr/data/bin/opt /opt
fi
for f in opencreator-installer install.sh payload/installers; do
    [ -e "$OC/$f" ] || { echo "missing $OC/$f"; exit 1; }
done
export OC_MACHINE=${1:-} OC_PID=${2:-}
cp "$OC/opencreator-installer" /tmp/opencreator-installer
chmod 755 /tmp/opencreator-installer
mkdir -p "$BACKUPS"
rm -f /tmp/opencreator-quit
/tmp/opencreator-installer --splash "Starting..."

# app_startup.sh loads the touchscreen driver later than this script; it is
# loaded first so the Wi-Fi wait below can already offer Quit.
insmod /usr/prog/modules/gt9xx_touch.ko gtp_i2c_bus_num=0 gtp_x_coords_min=0 gtp_y_coords_min=0 gtp_x_coords_max=800 gtp_y_coords_max=480 gtp_x_coords_flip=0 gtp_y_coords_flip=0 gtp_x_y_coords_exchange=0 gtp_version=0x4 gtp_regulator_name=-1 gtp_power_on_gpio=-1 gtp_reset_gpio=PC08 gtp_irq_gpio=PC07 gtp_max_touch_number=2 2>/dev/null
i=0
until grep -q -i goodix /proc/bus/input/devices 2>/dev/null || [ $i -ge 10 ]; do
    sleep 1
    i=$((i + 1))
done
ls -l /dev/fb0 /dev/input/ 2>&1
grep "^N: Name=" /proc/bus/input/devices 2>&1

# Quit on this screen (Wi-Fi not connecting, for example) skips the installer.
/tmp/opencreator-installer --wait "Connecting to Wi-Fi..." &
wait_pid=$!
quit() { [ -e /tmp/opencreator-quit ]; }

# app_startup.sh runs this before it loads the Wi-Fi driver.
insmod /usr/prog/modules/8821cu.ko power_on=PB07 2>/dev/null
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ $i -lt 20 ] && ! quit; do
    sleep 1
    i=$((i + 1))
done
if quit; then
    :
elif [ -e /sys/class/net/wlan0 ] && grep -q 'network=' "$WPA_CONF" 2>/dev/null; then
    ifconfig wlan0 up
    pidof wpa_supplicant >/dev/null || wpa_supplicant -Dnl80211 -iwlan0 -c"$WPA_CONF" -B
    pidof udhcpc >/dev/null || udhcpc -i wlan0 -b
else
    echo "no Wi-Fi adapter or saved network"
fi

i=0
until quit || ping -c1 -W2 github.com >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 2
    i=$((i + 1))
done
kill "$wait_pid" 2>/dev/null
wait "$wait_pid" 2>/dev/null
if quit; then
    echo "Quit on the Wi-Fi screen; continuing the normal boot"
    rm -f /tmp/opencreator-quit
    sync
    exit 1
fi
rdate -s time.nist.gov 2>/dev/null || echo "clock not set"

/tmp/opencreator-installer --splash "Starting the installer..."
sync
/tmp/opencreator-installer "$OC/payload" "$BACKUPS" "$OC/install.sh"
rc=$?
sync
echo "installer exited with $rc; continuing the normal boot"
sync
exit 1
