#!/bin/sh
# x86-64 SDL demo only. Never invokes the real installer; the only file it
# writes is a /tmp marker for the demo Wi-Fi connection.
# OC_DEMO_OFFLINE=1 starts without internet (the Wi-Fi screens); the demo
# networks accept any 8 to 63 character password. OC_DEMO_INSTALLED=0.0.3
# shows the up-to-date screen.
DEMO_ONLINE=/tmp/opencreator-demo-online
case "$1" in
    check)
        echo "MODEL ${OC_MACHINE:-Creator5Pro} ${OC_PID:-0029}"
        if [ "${OC_DEMO_OLD_KERNEL:-0}" = 1 ]; then
            echo 'KERNEL MISMATCH 1.9.0'
        else
            echo 'KERNEL OK 2.0.7'
        fi
        echo 'STAGE Demo mode: no printer files will be changed'
        echo 'WARN Demo warning: backup drive has 120 MB free'
        echo 'BACKUP /tmp/opencreator-installer-demo/opencreator-20260101T000000Z-1'
        # OC_DEMO_INSTALLED=<version>: a previous install of that version
        # (this installer's version shows the up-to-date screen).
        if [ -n "${OC_DEMO_INSTALLED:-}" ]; then
            echo "VERSION ${OC_DEMO_VERSION:-0.0.3}"
            echo "RELEASE Public Alpha 3"
            echo "PREVIOUS $OC_DEMO_INSTALLED soc fluidd yes"
        fi
        if [ "${OC_DEMO_OFFLINE:-0}" = 1 ] && [ ! -e "$DEMO_ONLINE" ]; then
            echo 'NETWORK DOWN'
        else
            echo 'NETWORK OK'
        fi ;;
    wifi-scan)
        echo 'STAGE Scanning for Wi-Fi networks'; sleep 2
        [ -e "$DEMO_ONLINE" ] || [ "${OC_DEMO_OFFLINE:-0}" != 1 ] && echo 'WIFINOW Home WiFi'
        echo 'WIFI -45 1 Home WiFi'
        echo 'WIFI -58 1 Home WiFi 5G'
        echo 'WIFI -67 1 NETGEAR42'
        echo 'WIFI -74 0 Coffee Shop Guest'
        echo 'WIFI -81 1 DIRECT-HP-Printer' ;;
    wifi-connect)
        echo "STAGE Connecting to $OC_WIFI_SSID"; sleep 2
        # Like the real backend: WPA passwords are 8 to 63 characters.
        if [ -n "$OC_WIFI_PSK" ] && { [ ${#OC_WIFI_PSK} -lt 8 ] || [ ${#OC_WIFI_PSK} -gt 63 ]; }; then
            echo "ERROR Wi-Fi passwords are 8 to 63 characters"
            exit 1
        fi
        : > "$DEMO_ONLINE"
        echo "STAGE Clock set: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "STAGE Connected to $OC_WIFI_SSID" ;;
    install)
        echo 'PROGRESS 0 5'
        echo 'STAGE Simulating backup of PROGRAM, Moonraker, OpenCreator and web UIs'; sleep 1
        echo 'PROGRESS 1 5'
        echo 'STAGE Simulating Entware and LoopScript'; sleep 1
        echo 'PROGRESS 2 5'
        if [ "$4" = soc ]; then
            echo "STAGE Simulating Kalico, Moonraker, Mainsail and Fluidd (serving $5)"; sleep 1
        else
            echo 'STAGE Simulating the socat bridge'; sleep 1
        fi
        echo 'PROGRESS 3 5'
        echo "STAGE GrumpyScreen choice: $6"; sleep 1
        echo 'PROGRESS 5 5'
        echo 'STAGE Demo complete, no changes made' ;;
    restore)
        for i in 1 2 3; do echo "PROGRESS $i 3"; echo "STAGE Simulating restore step $i"; sleep 1; done
        echo 'STAGE Demo restore complete, no changes made' ;;
    *) echo 'ERROR Unknown demo action'; exit 1 ;;
esac
