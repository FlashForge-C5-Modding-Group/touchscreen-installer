#!/bin/sh
# OpenCreator installer backend. Arguments are supplied by the LVGL frontend.
set -eu

ACTION=${1:?action required}
PAYLOAD=${2:?payload path required}
BACKUP_ROOT=${3:?backup path required}
MODE=${4:-soc}
WEB=${5:-fluidd}
TOUCHSCREEN=${6:-yes}
# Demo mode: when set, `install` writes everything under this one
# directory instead of the real system paths, and skips the root
# requirement, so the whole payload-stage pipeline can be run and
# inspected on an ordinary dev machine. Exported so every payload
# script (payload-template/{soc,tunnel,common}/*.sh) sees it and
# prefixes its own absolute paths the same way.
DEMO_ROOT=${OC_DEMO_ROOT:-}
export OC_DEMO_ROOT="$DEMO_ROOT"
# Entware (installed by the first payload step) provides git, curl, gcc
# and Python; later steps find it here.
export PATH=/opt/bin:/opt/sbin:$PATH
# Started from the USB boot hook, HOME is the read-only / (pip then fails to
# write /.cache), and /tmp is a small RAM disk; use /usr/data for both.
if [ -z "$DEMO_ROOT" ]; then
    if [ -z "${HOME:-}" ] || ! touch "$HOME/.oc-write-test" 2>/dev/null; then
        export HOME=/usr/data/opencreator/home
    fi
    rm -f "$HOME/.oc-write-test"
    export TMPDIR=/usr/data/opencreator/tmp
    mkdir -p "$HOME" "$TMPDIR"
    rm -rf "${TMPDIR:?}"/* 2>/dev/null || true
fi
STATE_DIR=${OC_STATE_DIR:-"$DEMO_ROOT/usr/data/opencreator"}
INSTALL_STATE=$STATE_DIR/install.json
INSTALLER_VERSION=0.0.1
INSTALLER_RELEASE="Public Alpha Version 1"
MIN_FREE_KB=${OC_MIN_FREE_KB:-262144}
BACKUP_FOLDERS="usr/prog/PROGRAM/software/firmwareExe usr/prog/moonraker usr/data/opencreator
usr/data/mainsail usr/data/fluidd usr/data/nginx usr/prog/c5-tunnel-socat
usr/prog/logo.jpeg usr/prog/app_startup.sh"

# Other custom firmware OpenCreator replaces, and the old Moonraker copies
# left in /usr/prog/moonraker (moonraker-old, moonraker-env-old, numbered or
# not): backed up, then removed.
FOREIGN_FOLDERS="usr/data/zmod usr/data/.mod usr/data/anvil"
# A new install needs this much free on /usr/data (updates and config changes don't).
NEW_INSTALL_MIN_KB=${OC_NEW_INSTALL_MIN_KB:-2097152}

stage() { printf 'STAGE %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
progress() { printf 'PROGRESS %s %s\n' "$1" "$2"; }
die() { printf 'ERROR %s\n' "$*"; exit 1; }
# Sets MACHINE/PID from the stock boot script, which declares exactly
# one of the two supported pairs. OC_MACHINE/OC_PID override it.
detect_model() {
    MACHINE=${OC_MACHINE:-}
    PID=${OC_PID:-}
    if [ -z "$MACHINE" ]; then
        for f in "$DEMO_ROOT/usr/prog/app_startup.sh" "$DEMO_ROOT/usr/prog/PROGRAM/runFirmwareExe.sh"; do
            [ -r "$f" ] || continue
            MACHINE=$(sed -n 's/^[[:space:]]*MACHINE=\([A-Za-z0-9]*\).*/\1/p' "$f" | head -n 1)
            PID=$(sed -n 's/^[[:space:]]*PID=\([0-9]*\).*/\1/p' "$f" | head -n 1)
            [ -n "$MACHINE" ] && break
        done
    fi
    if [ -z "$MACHINE" ] && [ -n "$DEMO_ROOT" ]; then
        MACHINE=Creator5Pro
        PID=0029
    fi
    case "$MACHINE:$PID" in
        Creator5Pro:0029|Creator5:0028) return 0 ;;
    esac
    MACHINE=unknown
    PID=unknown
    return 1
}
# Sets KERNEL_PACKAGE from /usr/prog/PROGRAM/kernel/<version> and NAN_ADDR
# to that kernel's legacy-NaN switch (as in 01-fixnan.sh). OC_KERNEL_PACKAGE
# overrides it, and demo installs default to 2.0.7 (FlashForge 1.9.9).
kernel_supported() {
    KERNEL_PACKAGE=${OC_KERNEL_PACKAGE:-$(ls "$DEMO_ROOT/usr/prog/PROGRAM/kernel/" 2>/dev/null | head -n 1)}
    if [ -z "$KERNEL_PACKAGE" ] && [ -n "$DEMO_ROOT" ]; then KERNEL_PACKAGE=2.0.7; fi
    case "$KERNEL_PACKAGE" in
        2.0.1|2.0.2|2.0.3|2.0.4|2.0.5|2.0.6) NAN_ADDR=0x00a130d1 ;;
        2.0.7) NAN_ADDR=0x00B330D1 ;;
        2.0.8) NAN_ADDR=0x00B030D1 ;;
        *) KERNEL_PACKAGE=${KERNEL_PACKAGE:-unknown}; NAN_ADDR=; return 1 ;;
    esac
}
free_kb() {
    df -kP "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}
preflight() {
    data_dir=$DEMO_ROOT/usr/data
    [ -d "$data_dir" ] || data_dir=${DEMO_ROOT:-/}
    avail=$(free_kb "$data_dir")
    if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_KB" ]; then
        warn "Low space on /usr/data: $((avail / 1024)) MB free, $((MIN_FREE_KB / 1024)) MB recommended"
    fi
    if [ ! -d "$BACKUP_ROOT" ]; then
        warn "Backup destination missing: $BACKUP_ROOT"
    elif [ ! -w "$BACKUP_ROOT" ]; then
        warn "Backup destination is not writable: $BACKUP_ROOT"
    else
        avail=$(free_kb "$BACKUP_ROOT")
        if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_KB" ]; then
            warn "Low space on backup drive: $((avail / 1024)) MB free"
        fi
    fi
    for m in soc tunnel; do
        set -- "$PAYLOAD/installers/$m"/*.sh
        [ -f "$1" ] || warn "No $m installer scripts in payload"
    done
}
# Everything an install needs is downloaded; demo installs count as online.
online() {
    [ -n "$DEMO_ROOT" ] && return 0
    ping -c1 -W3 github.com >/dev/null 2>&1 || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1
}
require_online() {
    online || die "No internet connection. Connect the printer to Wi-Fi and try again; nothing was changed"
}

# Wi-Fi through FlashForge's own wpa_supplicant (control socket, update_config).
WPA_CONF=/usr/prog/wifi/wpa_supplicant.conf
wpa() { wpa_cli -i wlan0 "$@"; }
wifi_up() {
    [ -e /sys/class/net/wlan0 ] || die "No Wi-Fi adapter found"
    ifconfig wlan0 up 2>/dev/null
    if ! pidof wpa_supplicant >/dev/null; then
        wpa_supplicant -Dnl80211 -iwlan0 -c"$WPA_CONF" -B || die "Cannot start Wi-Fi"
        sleep 2
    fi
    pidof udhcpc >/dev/null || udhcpc -i wlan0 -b >/dev/null 2>&1
}
# WIFI <signal dBm> <secured 0|1> <ssid>, strongest first, one line per SSID.
wifi_scan() {
    wifi_up
    stage "Scanning for Wi-Fi networks"
    current=$(wpa status 2>/dev/null | sed -n 's/^ssid=//p' | head -n 1)
    [ -z "$current" ] || printf 'WIFINOW %s\n' "$current"
    wpa scan >/dev/null
    sleep 4
    # Hidden networks show up as an empty SSID or as \x00 escapes.
    wpa scan_results | awk -F'\t' 'NR > 1 && $5 ~ /[[:graph:]]/ && index($5, "\\x00") == 0 {
            secured = ($4 ~ /WPA|WEP|RSN/) ? 1 : 0
            if (!($5 in best) || $3 > best[$5]) { best[$5] = $3; sec[$5] = secured }
        }
        END { for (s in best) printf "WIFI %d %d %s\n", best[s], sec[s], s }' |
        sort -k2,2nr | head -n 15
}
# OC_WIFI_SSID / OC_WIFI_PSK (empty for an open network). Saved to the config
# only once it connects; a failure reloads the saved config.
wifi_connect() {
    ssid=${OC_WIFI_SSID:?}
    psk=${OC_WIFI_PSK:-}
    if [ -n "$psk" ] && { [ ${#psk} -lt 8 ] || [ ${#psk} -gt 63 ]; }; then
        die "Wi-Fi passwords are 8 to 63 characters"
    fi
    wifi_up
    stage "Connecting to $ssid"
    id=$(wpa add_network | tail -n 1) || true
    case "$id" in *[!0-9]*|'') die "Cannot add the Wi-Fi network" ;; esac
    # Quoted: wpa_supplicant reads up to the last quote, so spaces, quotes
    # and UTF-8 in the name are fine (busybox od can't make hex here).
    ok=$(wpa set_network "$id" ssid "\"$ssid\"") || true
    if [ -n "$psk" ]; then
        ok="$ok $(wpa set_network "$id" psk "\"$psk\"" || true)"
    else
        ok="$ok $(wpa set_network "$id" key_mgmt NONE || true)"
    fi
    if [ "$(echo $ok)" != "OK OK" ]; then
        wpa remove_network "$id" >/dev/null 2>&1
        die "Cannot set up $ssid (wpa_cli: $(echo $ok))"
    fi
    wpa select_network "$id" >/dev/null
    i=0
    until wpa status | grep -q '^wpa_state=COMPLETED' || [ $i -ge 30 ]; do
        sleep 1; i=$((i + 1))
    done
    if ! wpa status | grep -q '^wpa_state=COMPLETED'; then
        wpa reconfigure >/dev/null
        die "Could not join $ssid. Check the password and try again"
    fi
    stage "Joined $ssid; getting an address"
    udhcpc -i wlan0 -n -q -t 10 >/dev/null 2>&1 || true
    i=0
    until online || [ $i -ge 15 ]; do sleep 2; i=$((i + 1)); done
    online || { wpa reconfigure >/dev/null; die "Joined $ssid but there is no internet through it"; }
    wpa save_config >/dev/null || warn "Connected, but the Wi-Fi settings could not be saved"
    set_clock
    stage "Connected to $ssid"
}
# The clock is wrong after a boot without network, and HTTPS downloads fail
# on a wrong date: NTP first, then the time protocol (rdate).
set_clock() {
    stage "Setting the clock"
    if busybox ntpd -n -q -p pool.ntp.org >/dev/null 2>&1 ||
        busybox ntpd -n -q -p time.google.com >/dev/null 2>&1 ||
        rdate -s time.nist.gov >/dev/null 2>&1 || rdate -s time-a-g.nist.gov >/dev/null 2>&1; then
        stage "Clock set: $(date -u '+%Y-%m-%d %H:%M UTC')"
    else
        warn "Could not reach a time server; the clock may be wrong"
    fi
}
# FlashForge firmware version: app_startup.sh runs the highest numbered
# folder in software/. OC_FF_VERSION overrides it; demo installs count as 1.9.9.
detect_ff_version() {
    FF_VERSION=${OC_FF_VERSION:-}
    [ -z "$FF_VERSION" ] || return 0
    for dir in "$DEMO_ROOT"/usr/prog/PROGRAM/software/[0-9]*/; do
        [ -d "$dir" ] && basename "$dir"
    done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 > "${TMPDIR:-/tmp}/oc-ffver.$$"
    FF_VERSION=$(cat "${TMPDIR:-/tmp}/oc-ffver.$$"); rm -f "${TMPDIR:-/tmp}/oc-ffver.$$"
    [ -n "$FF_VERSION" ] || { [ -n "$DEMO_ROOT" ] && FF_VERSION=1.9.9; } || FF_VERSION=unknown
}
# Tunneled needs FlashForge 1.9.9; an undetectable version isn't blocked.
tunnel_supported() {
    detect_ff_version
    [ "$FF_VERSION" = unknown ] && return 0
    printf '%s\n' "$FF_VERSION" | awk -F. '{exit !($1 * 1000000 + $2 * 1000 + $3 >= 1009009)}'
}
foreign_name() {
    case "$1" in
        usr/data/zmod|usr/data/.mod) echo ZMod ;;
        usr/data/anvil) echo Reforge ;;
        usr/prog/moonraker/*) echo Moonraker ;;
    esac
}
# The foreign folders present on this printer, one per line.
foreign_folders() {
    for folder in $FOREIGN_FOLDERS; do
        [ ! -e "$DEMO_ROOT/$folder" ] || echo "$folder"
    done
    for dir in "$DEMO_ROOT"/usr/prog/moonraker/moonraker-old* \
               "$DEMO_ROOT"/usr/prog/moonraker/moonraker-env-old*; do
        [ ! -e "$dir" ] || echo "${dir#"$DEMO_ROOT"/}"
    done
}
# Free KB on /usr/data, counting what removing ZMod/Reforge frees up.
usable_kb() {
    data_dir=$DEMO_ROOT/usr/data
    [ -d "$data_dir" ] || data_dir=${DEMO_ROOT:-/}
    kb=$(free_kb "$data_dir")
    [ -n "$kb" ] || return 1
    for folder in $(foreign_folders); do
        used=$(du -sk "$DEMO_ROOT/$folder" 2>/dev/null | awk '{print $1}')
        kb=$((kb + ${used:-0}))
    done
    echo "$kb"
}
# Only a new install (no install record) is held to NEW_INSTALL_MIN_KB.
space_ok() {
    [ -f "$INSTALL_STATE" ] && return 0
    usable=$(usable_kb) || return 0
    [ "$usable" -ge "$NEW_INSTALL_MIN_KB" ]
}
remove_foreign() {
    for folder in $(foreign_folders); do
        case $folder in
            usr/prog/moonraker/*) stage "Removing the old Moonraker copy /$folder" ;;
            *) stage "Removing the previous $(foreign_name "$folder") install (/$folder)" ;;
        esac
        rm -rf "$DEMO_ROOT/$folder" || die "could not remove /$folder"
    done
}
latest_backup() {
    LATEST_BACKUP=
    if [ -f "$INSTALL_STATE" ]; then
        recorded=$(sed -n 's/^  "backup": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        if [ -n "$recorded" ] && [ -d "$recorded" ]; then LATEST_BACKUP=$recorded; fi
    fi
    if [ -z "$LATEST_BACKUP" ] && [ -d "$BACKUP_ROOT" ]; then
        for dir in "$BACKUP_ROOT"/opencreator-*; do
            if [ -d "$dir" ]; then LATEST_BACKUP=$dir; fi
        done
    fi
    [ -n "$LATEST_BACKUP" ]
}
check() {
    printf 'VERSION %s\n' "$INSTALLER_VERSION"
    printf 'RELEASE %s\n' "$INSTALLER_RELEASE"
    if detect_model; then
        printf 'MODEL %s %s\n' "$MACHINE" "$PID"
    else
        printf 'MODEL unknown unknown\n'
        warn "Printer model not detected (expected Creator5 or Creator5Pro in /usr/prog/app_startup.sh)"
    fi
    if kernel_supported; then
        printf 'KERNEL OK %s\n' "$KERNEL_PACKAGE"
    else
        printf 'KERNEL MISMATCH %s\n' "$KERNEL_PACKAGE"
    fi
    # MCU firmware on the drive for this model, and what the boards last got.
    mcu=none
    for manifest in "$PAYLOAD/mcu-firmware/${MACHINE:-none}"-*.tgz.manifest.json; do
        [ -f "$manifest" ] || continue
        mcu=$(sed -n 's/.*"commit": *"\([0-9a-f]\{7,40\}\)".*/\1/p' "$manifest" | head -n 1)
    done
    flashed=$(cat "$STATE_DIR/mcu-firmware.commit" 2>/dev/null || echo none)
    printf 'MCU %s %s\n' "${mcu:-none}" "$flashed"
    if [ -f "$INSTALL_STATE" ]; then
        previous_version=$(sed -n 's/^  "installer_version": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        previous_mode=$(sed -n 's/^  "mode": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        previous_web=$(sed -n 's/^  "web_ui": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        previous_touch=$(sed -n 's/^  "touchscreen": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        stage "Previous OpenCreator $previous_version: $previous_mode, $previous_web, touchscreen $previous_touch"
        printf 'PREVIOUS %s %s %s %s\n' "${previous_version:-?}" "${previous_mode:-?}" \
            "${previous_web:-?}" "${previous_touch:-?}"
    else
        stage "No prior OpenCreator install record"
    fi
    preflight
    if online; then printf 'NETWORK OK\n'; else printf 'NETWORK DOWN\n'; fi
    warned=
    for folder in $(foreign_folders); do
        name=$(foreign_name "$folder")
        case " $warned " in *" $name "*) continue ;; esac
        warned="$warned $name"
        if [ "$name" = Moonraker ]; then
            warn "Old Moonraker copies found in /usr/prog/moonraker! These will be backed up and removed!"
        else
            warn "Previous $name install detected! This will be backed up and removed!"
        fi
    done
    detect_ff_version
    printf 'FIRMWARE %s\n' "$FF_VERSION"
    tunnel_supported ||
        stage "FlashForge firmware $FF_VERSION: Tunneled needs 1.9.9"
    if ! space_ok; then
        printf 'SPACE LOW %s\n' "$(($(usable_kb) / 1024))"
        warn "Only $(($(usable_kb) / 1024)) MB free on the printer (/usr/data). A new install needs 2 GB free: free up space first. Updates and config changes still work."
    fi
    if latest_backup; then printf 'BACKUP %s\n' "$LATEST_BACKUP"; fi
    # The LoopScript launcher is a shell script; stock firmwareExe is ELF.
    fe=$DEMO_ROOT/usr/prog/PROGRAM/software/firmwareExe
    if [ -f "$fe" ] && [ "$(dd if="$fe" bs=1 skip=1 count=3 2>/dev/null)" != ELF ] &&
        stock=$(stock_firmware_exe); then
        printf 'STOCK %s\n' "$stock"
    fi
}
backup_folders() {
    [ -n "$DEMO_ROOT" ] || [ "$(id -u)" -eq 0 ] || die "backup requires root"
    [ -d "$BACKUP_ROOT" ] || die "backup destination missing: $BACKUP_ROOT"
    [ -w "$BACKUP_ROOT" ] || die "backup destination is not writable"
    case "$BACKUP_ROOT" in
        /*) ;;
        *) die "backup destination must be absolute" ;;
    esac
    BACKUP_ROOT=$(readlink -f "$BACKUP_ROOT") || die "cannot resolve backup destination"
    case "$BACKUP_ROOT" in
        /usr/prog/PROGRAM|/usr/prog/PROGRAM/*|/usr/prog/moonraker|/usr/prog/moonraker/*|\
/usr/data/opencreator|/usr/data/opencreator/*|/usr/data/mainsail|/usr/data/mainsail/*|\
/usr/data/fluidd|/usr/data/fluidd/*|/usr/data/nginx|/usr/data/nginx/*|\
/usr/prog/c5-tunnel-socat|/usr/prog/c5-tunnel-socat/*)
            die "backup destination cannot be inside a source directory" ;;
        *[!A-Za-z0-9_./-]*) die "backup path contains unsupported characters" ;;
    esac
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    target=$BACKUP_ROOT/opencreator-$stamp-$$
    mkdir "$target" || die "cannot create backup directory"
    : > "$target/absent.list"
    # Old Moonraker copies are already inside the usr/prog/moonraker archive.
    for folder in ${1:-$BACKUP_FOLDERS $(foreign_folders | grep -v '^usr/prog/moonraker/')}; do
        if [ -e "$DEMO_ROOT/$folder" ]; then
            name=$(printf '%s' "$folder" | tr / _)
            stage "Backing up /$folder"
            # The printer's busybox tar has no -z, so compress separately.
            tar -C "${DEMO_ROOT:-/}" -cf "$target/$name.tar.tmp" "$folder" || die "backup failed: /$folder"
            mv "$target/$name.tar.tmp" "$target/$name.tar"
            if command -v gzip >/dev/null 2>&1; then
                gzip -f "$target/$name.tar" || die "backup compression failed: /$folder"
            fi
        else
            stage "Not present, skipping /$folder"
            printf '%s\n' "$folder" >> "$target/absent.list"
        fi
    done
    BACKUP_TARGET=$target
    stage "Backup complete: $BACKUP_TARGET"
}
install_payload() {
    [ -n "$DEMO_ROOT" ] || [ "$(id -u)" -eq 0 ] || die "installation requires root"
    case "$MODE" in soc|tunnel) ;; *) die "invalid install mode" ;; esac
    case "$WEB" in mainsail|fluidd|none) ;; *) die "invalid web UI" ;; esac
    case "$TOUCHSCREEN" in yes|no) ;; *) die "invalid touchscreen choice" ;; esac
    [ "$MODE" != tunnel ] || [ "$WEB" = none ] || die "tunnel mode must skip web UI"
    [ "$MODE" != tunnel ] || tunnel_supported ||
        die "Tunneled needs FlashForge firmware 1.9.9 (this printer has $FF_VERSION). Update the printer to 1.9.9 first; nothing was changed"
    [ "$MODE" != soc ] || [ "$WEB" != none ] || die "SoC mode requires a web UI"
    detect_model || die "unsupported or undetected printer model"
    stage "Detected $MACHINE (PID $PID)"
    # Over an existing install the steps update in place and keep user files
    # and custom configs; the web UIs are left to Moonraker's update manager.
    UPDATE=0
    [ ! -f "$INSTALL_STATE" ] || UPDATE=1
    missing_tools=
    for tool in tar gzip gunzip md5sum sed grep awk find mktemp wget od dd; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools="$missing_tools $tool"
    done
    [ -z "$missing_tools" ] || die "the printer is missing:$missing_tools; nothing was changed"
    kernel_supported || die "unsupported FlashForge kernel package $KERNEL_PACKAGE (legacy NaN address unknown)"
    space_ok || die "only $(($(usable_kb) / 1024)) MB free on /usr/data; a new install needs $((NEW_INSTALL_MIN_KB / 1024)) MB. Nothing was changed"
    stage "Kernel package $KERNEL_PACKAGE"
    scripts=$PAYLOAD/installers/$MODE
    [ -d "$scripts" ] || die "install scripts missing: $scripts"
    found=0
    total=2
    for script in "$scripts"/*.sh; do
        [ -f "$script" ] || continue
        found=1
        total=$((total + 1))
        [ ! -L "$script" ] || die "symlinked installer refused: $script"
    done
    [ "$found" -eq 1 ] || die "no installer scripts in $scripts"
    progress 0 "$total"
    if [ "${OC_SKIP_BACKUP:-0}" = 1 ]; then
        stage "Skipping the backup (Install without backup)"
        # ZMod/Reforge and old Moonraker copies are still archived before
        # they are removed.
        foreign=$(foreign_folders)
        [ -z "$foreign" ] || backup_folders "$foreign"
        # Payload steps still keep small "previous" copies here.
        BACKUP_TARGET=$STATE_DIR/no-backup
        mkdir -p "$BACKUP_TARGET"
        RECORDED_BACKUP=none
    else
        backup_folders
        RECORDED_BACKUP=$BACKUP_TARGET
    fi
    remove_foreign
    n=1
    progress "$n" "$total"
    for script in "$scripts"/*.sh; do
        [ -f "$script" ] || continue
        n=$((n + 1))
        stage "Running ${script##*/}"
        OC_PAYLOAD="$PAYLOAD" OC_MODE="$MODE" OC_WEB_UI="$WEB" \
            OC_TOUCHSCREEN="$TOUCHSCREEN" OC_MACHINE="$MACHINE" OC_PID="$PID" \
            OC_KERNEL_PACKAGE="$KERNEL_PACKAGE" OC_NAN_ADDR="$NAN_ADDR" \
            OC_BACKUP="$BACKUP_TARGET" OC_UPDATE="$UPDATE" OC_KEEP_WEB="$UPDATE" \
            /bin/sh "$script" || die "failed: ${script##*/}"
        progress "$n" "$total"
    done
    write_state
    progress "$total" "$total"
    stage "OpenCreator installation complete"
}
# Restores the newest backup. Archives may be rooted at / (backup_folders)
# or (older installers) at the folder's parent, so check the first entry.
unpack() {
    case "$1" in
        *.gz) gunzip -c "$1" ;;
        *) cat "$1" ;;
    esac
}
restore_backup() {
    [ -n "$DEMO_ROOT" ] || [ "$(id -u)" -eq 0 ] || die "restore requires root"
    latest_backup || die "no OpenCreator backup found in $BACKUP_ROOT"
    case "$LATEST_BACKUP" in
        *[!A-Za-z0-9_./-]*) die "backup path contains unsupported characters" ;;
    esac
    stage "Restoring from $LATEST_BACKUP"
    total=0
    for folder in $BACKUP_FOLDERS; do total=$((total + 1)); done
    n=0
    progress 0 "$total"
    for folder in $BACKUP_FOLDERS; do
        n=$((n + 1))
        archive=$LATEST_BACKUP/$(printf '%s' "$folder" | tr / _).tar
        [ -f "$archive" ] || archive=$archive.gz
        if [ -f "$archive" ]; then
            case "$archive" in
                *.gz) gunzip -t "$archive" || die "backup archive damaged: ${archive##*/}" ;;
            esac
            first=$(unpack "$archive" | tar -tf - | head -n 1) || die "backup archive unreadable: ${archive##*/}"
            case "$first" in
                usr/*) dest=${DEMO_ROOT:-/} ;;
                *) dest=$DEMO_ROOT/${folder%/*} ;;
            esac
            stage "Restoring /$folder"
            rm -rf "$DEMO_ROOT/$folder"
            mkdir -p "$dest"
            unpack "$archive" | tar -C "$dest" -xf - || die "restore failed: /$folder"
        elif grep -qx "$folder" "$LATEST_BACKUP/absent.list" 2>/dev/null; then
            stage "Removing /$folder (absent before install)"
            rm -rf "$DEMO_ROOT/$folder"
        fi
        progress "$n" "$total"
    done
    rm -f "$INSTALL_STATE"
    sync
    stage "Restore complete; reboot to start the restored stack"
}

write_state() {
    mkdir -p "$STATE_DIR"
    stage "Writing install record"
    printf '{\n  "installer_version": "%s",\n  "machine": "%s",\n  "pid": "%s",\n  "kernel_package": "%s",\n  "mode": "%s",\n  "web_ui": "%s",\n  "touchscreen": "%s",\n  "backup": "%s",\n  "installed_utc": "%s"\n}\n' \
        "$INSTALLER_VERSION" "$MACHINE" "$PID" "$KERNEL_PACKAGE" "$MODE" "$WEB" "$TOUCHSCREEN" \
        "$RECORDED_BACKUP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL_STATE.tmp"
    mv "$INSTALL_STATE.tmp" "$INSTALL_STATE"
    sync
}
state_value() {
    sed -n "s/^  \"$1\": \"\\([^\"]*\\)\",\$/\\1/p" "$INSTALL_STATE" | head -n 1
}
run_step() {  # run_step installers/MODE/NN-name.sh
    stage "Running ${1##*/}"
    OC_PAYLOAD="$PAYLOAD" OC_MODE="$MODE" OC_WEB_UI="$WEB" \
        OC_TOUCHSCREEN="$TOUCHSCREEN" OC_MACHINE="$MACHINE" OC_PID="$PID" \
        OC_KERNEL_PACKAGE="$KERNEL_PACKAGE" OC_NAN_ADDR="$NAN_ADDR" \
        OC_BACKUP="$BACKUP_TARGET" OC_UPDATE=1 OC_KEEP_WEB=1 /bin/sh "$PAYLOAD/$1" || die "failed: ${1##*/}"
}
# Update Configs: compares the choices with the install record and only
# applies what differs. Nothing is backed up and nothing already installed
# is downloaded again.
reconfigure() {
    [ -n "$DEMO_ROOT" ] || [ "$(id -u)" -eq 0 ] || die "changing the setup requires root"
    case "$MODE" in soc|tunnel) ;; *) die "invalid install mode" ;; esac
    case "$WEB" in mainsail|fluidd|none) ;; *) die "invalid web UI" ;; esac
    case "$TOUCHSCREEN" in yes|no) ;; *) die "invalid touchscreen choice" ;; esac
    [ "$MODE" != tunnel ] || [ "$WEB" = none ] || die "tunnel mode must skip web UI"
    [ "$MODE" != tunnel ] || tunnel_supported ||
        die "Tunneled needs FlashForge firmware 1.9.9 (this printer has $FF_VERSION). Update the printer to 1.9.9 first; nothing was changed"
    [ "$MODE" != soc ] || [ "$WEB" != none ] || die "SoC mode requires a web UI"
    [ -f "$INSTALL_STATE" ] || die "no OpenCreator install record; use Recovery instead"
    detect_model || die "unsupported or undetected printer model"
    kernel_supported || die "unsupported FlashForge kernel package $KERNEL_PACKAGE"
    old_mode=$(state_value mode)
    old_web=$(state_value web_ui)
    old_touch=$(state_value touchscreen)
    RECORDED_BACKUP=$(state_value backup)
    BACKUP_TARGET=$STATE_DIR/no-backup
    mkdir -p "$BACKUP_TARGET"
    OC=$DEMO_ROOT/usr/data/opencreator
    MR=$DEMO_ROOT/usr/prog/moonraker
    TUNNELED=$OC/tunneled/tunneled.sh
    GRUMPY_DIR=$DEMO_ROOT/usr/data/grumpyscreen

    steps=
    if [ "$MODE" != "$old_mode" ]; then
        stage "Switching from $old_mode to $MODE"
        if [ "$MODE" = tunnel ]; then
            steps="installers/tunnel/01-install-entware.sh installers/tunnel/10-install-tunnel.sh"
        else
            steps="installers/soc/01-install-entware.sh installers/soc/02-install-loopscript.sh installers/soc/05-install-python.sh"
            [ -f "$OC/klipper/klipper/klippy/klippy.py" ] && [ -x "$OC/klipper/klippy-env/bin/python" ] ||
                steps="$steps installers/soc/10-install-stack.sh"
            # Tunnel installs leave FlashForge's own Moonraker in place.
            git -C "$MR/moonraker" remote get-url origin 2>/dev/null | grep -q Arksine &&
                [ -x "$MR/moonraker-env/bin/python" ] ||
                steps="$steps installers/soc/15-install-moonraker.sh"
            steps="$steps installers/soc/17-install-timelapse.sh"
            steps="$steps installers/soc/20-install-web.sh"
        fi
    elif [ "$MODE" = soc ] && [ "$WEB" != "$old_web" ]; then
        steps="installers/soc/20-install-web.sh"
    fi
    if [ "$TOUCHSCREEN" = yes ] && [ "$old_touch" != yes ]; then
        [ -f "$GRUMPY_DIR/grumpyscreen" ] ||
            steps="$steps installers/$MODE/30-install-grumpyscreen.sh"
        [ -f "$GRUMPY_DIR/grumpyscreen.cfg" ] || case " $steps " in
            *" installers/$MODE/02-install-loopscript.sh "*) ;;
            *) steps="installers/$MODE/02-install-loopscript.sh $steps" ;;
        esac
    fi

    total=2
    for step in $steps; do total=$((total + 1)); done
    progress 0 "$total"
    n=0
    for step in $steps; do
        run_step "$step"
        n=$((n + 1))
        progress "$n" "$total"
    done
    # firmwareExe starts the bridge instead of startup.sh when this is
    # executable; set every time, since 02-install-loopscript.sh resets it.
    if [ -f "$TUNNELED" ]; then
        if [ "$MODE" = tunnel ]; then chmod 755 "$TUNNELED"; else chmod 644 "$TUNNELED"; fi
    fi
    [ "$MODE" = "$old_mode" ] || stage "LoopScript now starts the $MODE setup"
    if [ "$TOUCHSCREEN" != "$old_touch" ] && [ -f "$GRUMPY_DIR/grumpyscreen" ]; then
        # 40-grumpyscreen.sh only starts an executable binary.
        if [ "$TOUCHSCREEN" = yes ]; then
            chmod 755 "$GRUMPY_DIR/grumpyscreen"
            stage "GrumpyScreen turned on"
        else
            chmod 644 "$GRUMPY_DIR/grumpyscreen"
            stage "GrumpyScreen turned off (kept on the printer)"
        fi
    fi
    write_state
    progress "$total" "$total"
    stage "Changes applied; reboot to start with them"
}

# Rollback to stock: only FlashForge's firmwareExe goes back. Everything
# OpenCreator runs is started by the LoopScript firmwareExe, so the printer
# then boots as stock; OpenCreator's files stay on disk for a reinstall.
stock_firmware_exe() {
    versioned=$(ls -d "$DEMO_ROOT"/usr/prog/PROGRAM/software/[0-9]*/firmwareExe 2>/dev/null | tail -n 1)
    for f in "$STATE_DIR/firmwareExe.stock" $versioned \
        "$DEMO_ROOT/usr/prog/c5-tunnel-socat/firmwareExe.previous"; do
        if [ -f "$f" ] && [ "$(dd if="$f" bs=1 skip=1 count=3 2>/dev/null)" = ELF ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}
rollback_stock() {
    [ -n "$DEMO_ROOT" ] || [ "$(id -u)" -eq 0 ] || die "rollback requires root"
    FE=$DEMO_ROOT/usr/prog/PROGRAM/software/firmwareExe
    src=$(stock_firmware_exe) || die "no stock firmwareExe found on the printer; nothing was changed"
    progress 0 2
    stage "Restoring FlashForge's firmwareExe from $src"
    cp "$src" "$FE.new" || die "could not copy $src"
    chmod 755 "$FE.new"
    sync
    mv "$FE.new" "$FE" || die "could not replace firmwareExe"
    sync
    progress 1 2
    # Without the record the next installer run offers a fresh install.
    [ ! -f "$INSTALL_STATE" ] || mv "$INSTALL_STATE" "$INSTALL_STATE.rolled-back"
    sync
    progress 2 2
    stage "Rolled back to stock; reboot to start FlashForge's firmware"
}

case "$ACTION" in
    check) check ;;
    rollback) rollback_stock ;;
    install) require_online; install_payload ;;
    reconfigure) require_online; reconfigure ;;
    wifi-scan) wifi_scan ;;
    wifi-connect) wifi_connect ;;
    restore) restore_backup ;;
    *) die "unknown action" ;;
esac
