#!/bin/sh
# x86-64 SDL demo only. Never writes files or invokes the real installer.
case "$1" in
    check)
        if [ "${OC_DEMO_ROOTFS:-0}" = 1 ]; then echo 'STATE NEEDED';
        else echo 'STATE CURRENT'; fi
        echo 'STAGE Demo mode: no printer files will be changed' ;;
    rootfs)
        echo 'STAGE Simulating squashfs verification'; sleep 1
        echo 'STAGE Simulating vendor OTA update'; sleep 1 ;;
    install)
        echo 'STAGE Simulating backup of Klipper, PROGRAM, and config'; sleep 1
        echo "STAGE Simulating $5 installer scripts"; sleep 1
        if [ "$5" = soc ]; then
            echo "STAGE Simulating $6 web UI"; sleep 1
            echo "STAGE GrumpyScreen choice: $7"; sleep 1
        fi
        echo 'STAGE Demo complete, no changes made' ;;
    *) echo 'ERROR Unknown demo action'; exit 1 ;;
esac
