#!/bin/sh
# x86-64 SDL demo only. Never writes files or invokes the real installer.
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
        echo 'BACKUP /tmp/opencreator-installer-demo/opencreator-20260101T000000Z-1' ;;
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
