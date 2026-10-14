#!/bin/sh
# x86-64 SDL demo only. Never writes files or invokes the real installer.
case "$1" in
    check)
        echo "MODEL ${OC_MACHINE:-Creator5Pro} ${OC_PID:-0029}"
        if [ "${OC_DEMO_ROOTFS:-0}" = 1 ]; then echo 'STATE NEEDED';
        else echo 'STATE CURRENT'; fi
        echo 'STAGE Demo mode: no printer files will be changed'
        echo 'WARN Demo warning: backup drive has 120 MB free'
        echo 'BACKUP /tmp/opencreator-installer-demo/opencreator-20260101T000000Z-1' ;;
    rootfs)
        echo 'STAGE Simulating squashfs verification'; sleep 1
        echo 'STAGE Simulating vendor OTA update'; sleep 1 ;;
    install)
        echo 'PROGRESS 0 5'
        echo 'STAGE Simulating backup of Klipper, PROGRAM, and config'; sleep 1
        echo 'PROGRESS 1 5'
        echo "STAGE Simulating $5 installer scripts"; sleep 1
        echo 'PROGRESS 2 5'
        if [ "$5" = soc ]; then
            echo "STAGE Simulating $6 web UI"; sleep 1
            echo 'PROGRESS 3 5'
            echo "STAGE GrumpyScreen choice: $7"; sleep 1
        fi
        echo 'PROGRESS 5 5'
        echo 'STAGE Demo complete, no changes made' ;;
    restore)
        for i in 1 2 3; do echo "PROGRESS $i 3"; echo "STAGE Simulating restore step $i"; sleep 1; done
        echo 'STAGE Demo restore complete, no changes made' ;;
    *) echo 'ERROR Unknown demo action'; exit 1 ;;
esac
