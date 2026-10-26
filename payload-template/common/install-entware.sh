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
PACKAGES="git git-http curl ca-bundle gcc tar xz openssh-sftp-server"
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

# opkg reports "Updated list" even when the download was an error page (a
# redirect or captive portal), and then knows no packages at all. Check for
# a package every feed has; fetch the list again over http, then https.
CONF=/opt/etc/opkg.conf
# The saved list itself (gzipped), not opkg's view, which includes installed packages.
list_ok() { { gunzip -c "$lists/$feed" 2>/dev/null || cat "$lists/$feed"; } 2>/dev/null | grep -q '^Package: tar$'; }
repair_package_list() {
    lists=$(sed -n 's/^lists_dir [a-z]* //p' "$CONF" | head -n 1)
    lists=${lists:-/opt/var/opkg-lists}
    feed=$(sed -n 's/^src\/gz \([^ ]*\) .*/\1/p' "$CONF" | head -n 1)
    feed=${feed:-entware}
    list_ok && return 0
    echo "WARN Entware's package list is empty or damaged ($(wc -c < "$lists/$feed" 2>/dev/null || echo 0) bytes); downloading it again"
    for arch in mipsel-3.4 mipsel-3x all; do
        grep -q "^arch $arch " "$CONF" || echo "arch $arch 150" >> "$CONF"
    done
    mkdir -p "$lists"
    for url in "$ENTWARE/Packages.gz" "https://bin.entware.net/mipselsf-k3.4/Packages.gz"; do
        rm -f "$lists/$feed.tmp"
        { /opt/bin/curl -fsSL -m 180 "$url" 2>/dev/null || wget -q -O - "$url"; } > "$lists/$feed.tmp" &&
            gunzip -c "$lists/$feed.tmp" 2>/dev/null | grep -q '^Package: tar$' &&
            mv "$lists/$feed.tmp" "$lists/$feed" && list_ok && return 0
        echo "STAGE Package list from $url unusable ($(wc -c < "$lists/$feed.tmp" 2>/dev/null || echo 0) bytes)"
    done
    rm -f "$lists/$feed.tmp"
    df -h /opt 2>/dev/null | tail -n 1 | sed 's/^/STAGE Space on \/opt: /'
    die "Entware's package list can't be downloaded; check the printer's internet (a captive portal or DNS filter can block bin.entware.net)"
}

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
    repair_package_list
    echo "STAGE Installing Entware packages:$missing (this takes a while)"
    # shellcheck disable=SC2086
    oc_run_staged /opt/bin/opkg install $missing || die "opkg install failed"
else
    echo "STAGE All Entware packages already installed"
fi

# A download cut short can leave a package marked installed with files
# missing, or a program whose library never arrived (git-remote-https
# without libatomic.so.1). Find those packages and reinstall them.
INFO=/opt/lib/opkg/info
broken_packages() {
    for list in "$INFO"/*.list; do
        [ -f "$list" ] || continue
        package=$(basename "$list" .list)
        while IFS= read -r file; do
            file=${file%%	*}
            [ -e "$file" ] || [ -L "$file" ] || { echo "$package"; break; }
        done < "$list"
    done
    for package in $PACKAGES; do
        [ -f "$INFO/$package.list" ] || continue
        while IFS= read -r file; do
            file=${file%%	*}
            case $file in *.so|*.so.*) continue ;; esac
            [ -f "$file" ] && [ -x "$file" ] || continue
            [ "$(dd if="$file" bs=1 skip=1 count=3 2>/dev/null)" = ELF ] || continue
            LD_TRACE_LOADED_OBJECTS=1 "$file" 2>&1 | grep -q 'not found' && { echo "$package"; break; }
        done < "$INFO/$package.list"
    done
}
broken=$(broken_packages | sort -u | tr '\n' ' ')
if [ -n "$broken" ]; then
    echo "WARN Damaged Entware packages (an interrupted download?): $broken"
    /opt/bin/opkg update || die "opkg update failed"
    repair_package_list
    echo "STAGE Reinstalling $broken"
    # shellcheck disable=SC2086
    oc_run_staged /opt/bin/opkg install --force-reinstall $broken || die "opkg reinstall failed"
    broken=$(broken_packages | sort -u | tr '\n' ' ')
    [ -z "$broken" ] || die "Entware packages still damaged after reinstalling: $broken"
    echo "STAGE Entware packages repaired"
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
