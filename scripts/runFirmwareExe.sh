#!/bin/sh
# Run by the stock /usr/prog/app_startup.sh from the root of a FAT USB drive
# mounted at /mnt, with MACHINE and PID as arguments. On the Creator 5 the
# hook is /mnt/runFirmwareExe.sh (exiting 0 stops the boot here; any other
# exit code lets the normal boot continue); on the AD5X it is
# /mnt/flashforge_init.sh, and the boot always continues afterwards.
# make-usb.sh puts this script on the drive under both names.
USB=/mnt
OC=$USB/opencreator
BACKUPS=$OC/backups
WPA_CONF=/usr/prog/wifi/wpa_supplicant.conf

[ -d "$OC" ] || exit 1
exec >> "$OC/runFirmwareExe.log" 2>&1
echo "=== $(date) $*"

[ "$(uname -m)" = mips ] || { echo "not a FlashForge MIPS printer"; exit 1; }

# Legacy NaN and Entware first: anything that runs a shell needs them when
# the root shell is Entware's (for example /opt/bin/bash). The AD5X needs it
# too: its userland is NaN2008, but Entware's programs (grep among them) are
# legacy NaN. Tested on the AD5X with kernel package 2.0.1.
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
# the AD5X panel is landscape already; the C5 default (rotation 1) stands
[ "$OC_MACHINE" != AD5X ] || export OC_DISPLAY_ROTATE=0
cp "$OC/opencreator-installer" /tmp/opencreator-installer
chmod 755 /tmp/opencreator-installer
mkdir -p "$BACKUPS"
rm -f /tmp/opencreator-quit
/tmp/opencreator-installer --splash "Starting..."

# app_startup.sh loads the touchscreen driver later than this script; it is
# loaded first so the Wi-Fi wait below can already offer Quit.
if [ "$OC_MACHINE" = AD5X ]; then
    # the AD5X touch is a TSC2007; the actrue window is the raw-to-pixel
    # mapping, derived from the pointercal FlashForge ships (the installer
    # has no in-app calibration, so the driver must map correctly)
    insmod /module_driver/tsc2007_touch.ko tsc_irq_gpio=PC07 tsc_power_on_gpio=-1 tsc_regulator_name=-1 tsc_i2c_bus=0 tsc_i2c_addr=0x48 tsc_x_plate_ohms=660 tsc_max_rt=600 tsc_fuzzx=0 tsc_fuzzy=0 tsc_fuzzz=0 tsc_poll_period=0 tsc_x_coords_max=800 tsc_y_coords_max=480 tsc_xy_coords_exchange=0 tsc_x_coords_flip=0 tsc_y_coords_flip=1 tsc_x_actrue_min=309 tsc_x_actrue_max=3765 tsc_y_actrue_min=705 tsc_y_actrue_max=3447 2>/dev/null
    touch_name=touchscreen
else
    insmod /usr/prog/modules/gt9xx_touch.ko gtp_i2c_bus_num=0 gtp_x_coords_min=0 gtp_y_coords_min=0 gtp_x_coords_max=800 gtp_y_coords_max=480 gtp_x_coords_flip=0 gtp_y_coords_flip=0 gtp_x_y_coords_exchange=0 gtp_version=0x4 gtp_regulator_name=-1 gtp_power_on_gpio=-1 gtp_reset_gpio=PC08 gtp_irq_gpio=PC07 gtp_max_touch_number=2 2>/dev/null
    touch_name=goodix
fi
i=0
until grep -q -i "$touch_name" /proc/bus/input/devices 2>/dev/null || [ $i -ge 10 ]; do
    sleep 1
    i=$((i + 1))
done
ls -l /dev/fb0 /dev/input/ 2>&1
grep "^N: Name=" /proc/bus/input/devices 2>&1

# Quit on this screen (Wi-Fi not connecting, for example) skips the installer.
/tmp/opencreator-installer --wait "Connecting to Wi-Fi..." &
wait_pid=$!
quit() { [ -e /tmp/opencreator-quit ]; }

# The AD5X supports wired ethernet too (configured in FlashForge's JSON,
# like openad5x's network start); bring it up alongside the Wi-Fi attempt.
if [ "$OC_MACHINE" = AD5X ]; then
    # stock app_startup.sh mounts the writable /etc overlay only after this
    # hook; without it resolv.conf lands on the read-only rootfs
    grep -q " /etc " /proc/mounts || mount /usr/prog/etc /etc
    CFG=/usr/prog/config/Adventurer5M.json
    net_get() {
        sed -n '/"network"/,/}/s/.*"'"$1"'" *: *"\{0,1\}\([^",]*\).*/\1/p' "$CFG" | head -n 1
    }
    # init starts a dhcpcd that keeps rewriting resolv.conf (empty) and
    # fights udhcpc; stock kills it in app_startup.sh after this hook
    killall dhcpcd 2>/dev/null
    # stock sets the real MAC only later in app_startup.sh; without it every
    # installer boot looks like a brand-new device to the router. The driver
    # brings eth0 up early, and a MAC change needs the interface down.
    if [ -f /usr/prog/MAC ]; then
        ifconfig eth0 down
        ifconfig eth0 hw ether "$(cat /usr/prog/MAC)" || echo "eth0: MAC set failed"
    fi
    ifconfig eth0 up 2>/dev/null
    sleep 3
    if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ]; then
        if [ "$(net_get isManual)" = true ]; then
            ifconfig eth0 "$(net_get configIp)" netmask "$(net_get configNetmask)"
            gw=$(net_get configGateway)
            [ -n "$gw" ] && route add default gw "$gw"
            dns=$(net_get configDns)
            [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf
        else
            udhcpc -n -q -t 5 -i eth0
        fi
        echo "ethernet: cable present, isManual=$(net_get isManual) ip=$(net_get configIp)"
        ifconfig eth0 | head -2
        route -n
        # some routers refuse DNS to a device this early in its life; public
        # fallbacks keep the installer's downloads resolving either way
        grep -q "nameserver 1.1.1.1" /etc/resolv.conf 2>/dev/null || {
            echo "nameserver 1.1.1.1" >> /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        }
        gw=$(route -n | awk '$1 == "0.0.0.0" { print $2; exit }')
        [ -n "$gw" ] && ping -c1 -W3 "$gw" >/dev/null 2>&1 && echo "gateway ping ok" || echo "gateway ping FAIL ($gw)"
        ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo "internet ping ok" || echo "internet ping FAIL"
    else
        echo "ethernet: no cable"
    fi
fi

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

ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo "pre-installer: 1.1.1.1 ok" || echo "pre-installer: 1.1.1.1 FAIL"
echo "--- resolv.conf:"; cat /etc/resolv.conf
echo "--- nslookup via resolv:"; nslookup github.com 2>&1 | head -6
echo "--- nslookup via 8.8.8.8:"; nslookup github.com 8.8.8.8 2>&1 | head -6
wget -T 6 -q -O /dev/null http://1.1.1.1 2>/dev/null && echo "tcp80 to WAN ok" || echo "tcp80 to WAN FAIL"
/tmp/opencreator-installer --splash "Starting the installer..."
sync
/tmp/opencreator-installer "$OC/payload" "$BACKUPS" "$OC/install.sh"
rc=$?
sync
echo "installer exited with $rc; continuing the normal boot"
sync
exit 1
