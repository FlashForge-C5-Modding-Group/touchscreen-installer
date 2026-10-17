#!/bin/sh
# Entware on /usr/data/bin/opt, bind-mounted at /opt (Creator-5-Mods
# "Add Entware Package Manager" and "Enable Legacy NaN"), plus the
# packages the chosen mode needs.
set -eu
: "${OC_MODE:?}"
: "${OC_NAN_ADDR:?}"
DEMO_ROOT=${OC_DEMO_ROOT:-}
: "${OC_PAYLOAD:?}"
. "$OC_PAYLOAD/common/install-helpers.sh"

OPT_STORE=$DEMO_ROOT/usr/data/bin/opt
ENTWARE=http://bin.entware.net/mipselsf-k3.4
PACKAGES="git git-http curl ca-bundle gcc tar xz"
case "$OC_MODE" in
soc)
    # Python (and its libraries) come from python-hf, which is hard-float.
    PACKAGES="$PACKAGES swap-utils"
    ;;
tunnel)
    PACKAGES="$PACKAGES socat"
    ;;
esac

die() { echo "ERROR $*"; exit 1; }

if [ -n "$DEMO_ROOT" ]; then
    mkdir -p "$OPT_STORE"
    echo "STAGE Demo mode: would enable legacy NaN ($OC_NAN_ADDR), bind-mount" \
         "$OPT_STORE on /opt, install Entware from $ENTWARE and run:" \
         "opkg install" $PACKAGES
    exit 0
fi

echo "STAGE Setting the clock"
rdate -s time.nist.gov 2>/dev/null || echo "STAGE Clock not set (no time server); continuing"

echo "STAGE Enabling legacy NaN"
busybox devmem "$OC_NAN_ADDR" 8 1

if [ -x /opt/bin/opkg ]; then
    echo "STAGE Entware already installed"
else
    mkdir -p "$OPT_STORE"
    grep -q ' /opt ' /proc/mounts || mount --bind "$OPT_STORE" /opt \
        || die "cannot bind-mount $OPT_STORE on /opt"
fi
if [ ! -x /opt/bin/opkg ]; then
    echo "STAGE Installing Entware"
    wget -O - "$ENTWARE/installer/generic.sh" | sh || die "Entware installer failed"
fi
[ -x /opt/bin/opkg ] || die "opkg missing after the Entware install"

installed=$(/opt/bin/opkg list-installed 2>/dev/null | cut -d' ' -f1)
missing=
for package in $PACKAGES; do
    printf '%s\n' "$installed" | grep -qx "$package" || missing="$missing $package"
done
if [ -n "$missing" ]; then
    echo "STAGE Updating Entware package lists"
    /opt/bin/opkg update || die "opkg update failed"
    echo "STAGE Installing Entware packages:$missing (this takes a while)"
    # shellcheck disable=SC2086
    oc_run_staged /opt/bin/opkg install $missing || die "opkg install failed"
else
    echo "STAGE All Entware packages already installed"
fi

if [ ! -f /opt/include/stdio.h ]; then
    echo "STAGE Installing compiler headers"
    mkdir -p /opt/include
    wget -O - "$ENTWARE/include/include.tar.gz" | gunzip -c | tar x -C /opt/include \
        || die "header download failed"
fi

[ "$OC_MODE" != tunnel ] || [ -x /opt/bin/socat ] || die "Entware socat missing"
[ -x /opt/bin/git ] || die "Entware git missing"
[ -x /opt/bin/gcc ] || die "Entware gcc missing"

grep -q '/opt/bin' /etc/profile 2>/dev/null ||
    echo 'export PATH=/opt/bin:/opt/sbin:$PATH' >> /etc/profile
sync
echo "STAGE Entware ready"
