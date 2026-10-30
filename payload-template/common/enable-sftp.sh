#!/bin/sh
# SFTP over the printer's SSH login: Entware's sftp-server, plus
# opencreator-fs's startup/scripts/06-sftp.sh, which points dropbear at it
# on every boot. Run here once too, so SFTP works before the reboot.
set -eu
: "${OC_PAYLOAD:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
. "$OC_PAYLOAD/common/install-helpers.sh"
ENABLER=$DEMO_ROOT$OC_HOME/startup/scripts/06-sftp.sh

if [ -n "$DEMO_ROOT" ]; then
    echo "STAGE Demo mode: would install openssh-sftp-server and run $ENABLER"
    exit 0
fi
if [ -x /opt/libexec/sftp-server ]; then
    echo "STAGE Entware's sftp-server already installed"
else
    echo "STAGE Installing Entware's sftp-server"
    oc_run_staged /opt/bin/opkg install openssh-sftp-server ||
        { echo "WARN SFTP not enabled: cannot install openssh-sftp-server"; exit 0; }
fi
[ -x /opt/libexec/sftp-server ] ||
    { echo "WARN SFTP not enabled: sftp-server missing after the install"; exit 0; }
# SFTP is optional: a problem here is a warning, not a failed install.
if [ ! -f "$ENABLER" ]; then
    echo "WARN SFTP not enabled: the OpenCreator files have no startup/scripts/06-sftp.sh yet"
    exit 0
fi
/bin/sh "$ENABLER"
if grep -q ' /usr/sbin/dropbear ' /proc/mounts; then
    echo "STAGE SFTP enabled on port 22 (same login as SSH)"
else
    echo "WARN SFTP could not be enabled; see /tmp/opencreator.log"
fi
