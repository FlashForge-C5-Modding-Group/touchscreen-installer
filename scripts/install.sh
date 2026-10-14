#!/bin/sh
# OpenCreator installer backend. Arguments are supplied by the LVGL frontend.
set -eu

ACTION=${1:?action required}
ROOTFS=${2:?rootfs path required}
PAYLOAD=${3:?payload path required}
BACKUP_ROOT=${4:?backup path required}
MODE=${5:-soc}
WEB=${6:-mainsail}
TOUCHSCREEN=${7:-yes}
# Demo mode: when set, `install` (not `check`/`rootfs` -- there is no
# sane way to demo an actual squashfs OTA swap) writes everything under
# this one directory instead of the real system paths, and skips the
# root requirement, so the whole payload-stage pipeline can be run and
# inspected on an ordinary dev machine. Exported so every payload
# script (payload-template/{soc,tunnel,common}/*.sh) sees it and
# prefixes its own absolute paths the same way.
DEMO_ROOT=${OC_DEMO_ROOT:-}
export OC_DEMO_ROOT="$DEMO_ROOT"
STATE_DIR=${OC_STATE_DIR:-"$DEMO_ROOT/usr/data/opencreator"}
ROOTFS_STATE=$STATE_DIR/rootfs.state
INSTALL_STATE=$STATE_DIR/install.json
INSTALLER_VERSION=0.2.0
MIN_FREE_KB=${OC_MIN_FREE_KB:-262144}
BACKUP_FOLDERS="usr/prog/klipper usr/prog/PROGRAM usr/data/config
usr/data/klipper usr/prog/moonraker usr/prog/mainsail usr/data/fluidd"

stage() { printf 'STAGE %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
progress() { printf 'PROGRESS %s %s\n' "$1" "$2"; }
die() { printf 'ERROR %s\n' "$*"; exit 1; }
hash_image() {
    [ -f "$ROOTFS" ] || die "squashfs image missing: $ROOTFS"
    [ -f "$ROOTFS.sha256" ] || die "squashfs SHA-256 sidecar missing"
    expected=$(tr -d '\r\n ' < "$ROOTFS.sha256")
    case "$expected" in
        *[!0-9a-fA-F]*|'') die "invalid squashfs SHA-256 sidecar" ;;
    esac
    [ "${#expected}" -eq 64 ] || die "invalid squashfs SHA-256 length"
    actual=$(sha256sum "$ROOTFS")
    actual=${actual%% *}
    [ "$actual" = "$expected" ] || die "squashfs SHA-256 mismatch"
    magic=$(dd if="$ROOTFS" bs=4 count=1 2>/dev/null)
    [ "$magic" = hsqs ] || die "not a little-endian squashfs image"
    IMAGE_HASH=$actual
}
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
current_ota_version() {
    [ -r /etc/ota_bin/ota_local_method.sh ] || die "vendor OTA methods unavailable"
    # The stock OTA helper defines the version and boot-slot discovery logic.
    . /etc/ota_bin/ota_local_method.sh
    CURRENT_OTA_VERSION=$(local_get_current_version) || die "cannot read OTA version"
    case "$CURRENT_OTA_VERSION" in
        *[!0-9]*|'') die "invalid OTA version" ;;
    esac
}
rootfs_is_current() {
    [ "$ROOTFS" = - ] && return 0
    hash_image
    [ -f "$ROOTFS_STATE" ] || return 1
    read -r saved_hash saved_version < "$ROOTFS_STATE" || return 1
    [ "$saved_hash" = "$IMAGE_HASH" ] || return 1
    case "$saved_version" in *[!0-9]*|'') return 1 ;; esac
    current_ota_version
    [ "$CURRENT_OTA_VERSION" -ge "$saved_version" ]
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
    if detect_model; then
        printf 'MODEL %s %s\n' "$MACHINE" "$PID"
    else
        printf 'MODEL unknown unknown\n'
        warn "Printer model not detected (expected Creator5 or Creator5Pro in /usr/prog/app_startup.sh)"
    fi
    if rootfs_is_current; then
        printf 'STATE CURRENT\n'
    else
        printf 'STATE NEEDED\n'
    fi
    if [ -f "$INSTALL_STATE" ]; then
        previous_version=$(sed -n 's/^  "installer_version": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        previous_mode=$(sed -n 's/^  "mode": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        previous_web=$(sed -n 's/^  "web_ui": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        previous_touch=$(sed -n 's/^  "touchscreen": "\([^"]*\)",$/\1/p' "$INSTALL_STATE" | head -n 1)
        stage "Previous OpenCreator $previous_version: $previous_mode, $previous_web, touchscreen $previous_touch"
    else
        stage "No prior OpenCreator install record"
    fi
    preflight
    if latest_backup; then printf 'BACKUP %s\n' "$LATEST_BACKUP"; fi
}
update_rootfs() {
    [ "$(id -u)" -eq 0 ] || die "rootfs update requires root"
    if rootfs_is_current; then stage "Rootfs already installed"; return; fi
    current_ota_version
    next_version=$((CURRENT_OTA_VERSION + 1))
    vendor=$PAYLOAD/vendor/local_ota_update.sh
    [ -f "$vendor" ] || die "vendor local_ota_update.sh missing from payload/vendor"
    [ -r /etc/ota_bin/ota_update_rootfs_squashfs.sh ] || die "vendor rootfs writer unavailable"
    stage "Staging verified rootfs for vendor OTA"
    mkdir -p "$STATE_DIR"
    work=$(mktemp -d "$STATE_DIR/ota.XXXXXX") || die "cannot create OTA staging directory"
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    mkdir "$work/ota_v$next_version"
    image_md5=$(md5sum "$ROOTFS")
    image_md5=${image_md5%% *}
    image_size=$(wc -c < "$ROOTFS" | tr -d ' ')
    image_name=rootfs.squashfs.0000.$image_md5
    cp "$ROOTFS" "$work/ota_v$next_version/$image_name"
    printf 'current_version=%s\n' "$next_version" > "$work/ota_config.in"
    printf 'ota_version=%s\n\nimg_type=rootfs\nimg_name=rootfs.squashfs\nimg_size=%s\nimg_md5=%s\n' \
        "$next_version" "$image_size" "$image_md5" > "$work/ota_v$next_version/ota_update.in"
    printf '%s\n' "$image_md5" > "$work/ota_v$next_version/ota_md5_rootfs.squashfs.$image_md5"
    : > "$work/ota_v$next_version/ota_v$next_version.ok"
    stage "Writing inactive rootfs with vendor updater"
    /bin/sh "$vendor" "$work" || die "vendor rootfs update failed"
    printf '%s %s\n' "$IMAGE_HASH" "$next_version" > "$ROOTFS_STATE.tmp"
    mv "$ROOTFS_STATE.tmp" "$ROOTFS_STATE"
    sync
    stage "Rootfs staged; reboot required"
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
        /usr/prog/klipper|/usr/prog/klipper/*|/usr/prog/PROGRAM|/usr/prog/PROGRAM/*|/usr/data/config|/usr/data/config/*|\
/usr/data/klipper|/usr/data/klipper/*|/usr/prog/moonraker|/usr/prog/moonraker/*|\
/usr/prog/mainsail|/usr/prog/mainsail/*|/usr/data/fluidd|/usr/data/fluidd/*)
            die "backup destination cannot be inside a source directory" ;;
        *[!A-Za-z0-9_./-]*) die "backup path contains unsupported characters" ;;
    esac
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    target=$BACKUP_ROOT/opencreator-$stamp-$$
    mkdir "$target" || die "cannot create backup directory"
    : > "$target/absent.list"
    for folder in $BACKUP_FOLDERS; do
        if [ -d "$DEMO_ROOT/$folder" ]; then
            name=$(printf '%s' "$folder" | tr / _)
            stage "Backing up /$folder"
            tar -C "${DEMO_ROOT:-/}" -czf "$target/$name.tar.gz.tmp" "$folder" || die "backup failed: /$folder"
            mv "$target/$name.tar.gz.tmp" "$target/$name.tar.gz"
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
    [ "$MODE" != tunnel ] || [ "$TOUCHSCREEN" = no ] || die "tunnel mode must skip touchscreen"
    [ "$MODE" != soc ] || [ "$WEB" != none ] || die "SoC mode requires a web UI"
    detect_model || die "unsupported or undetected printer model"
    stage "Detected $MACHINE (PID $PID)"
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
    backup_folders
    n=1
    progress "$n" "$total"
    for script in "$scripts"/*.sh; do
        [ -f "$script" ] || continue
        n=$((n + 1))
        stage "Running ${script##*/}"
        OC_PAYLOAD="$PAYLOAD" OC_MODE="$MODE" OC_WEB_UI="$WEB" \
            OC_TOUCHSCREEN="$TOUCHSCREEN" OC_MACHINE="$MACHINE" OC_PID="$PID" \
            OC_BACKUP="$BACKUP_TARGET" /bin/sh "$script" || die "failed: ${script##*/}"
        progress "$n" "$total"
    done
    image_hash=none
    if [ "$ROOTFS" != - ]; then hash_image; image_hash=$IMAGE_HASH; fi
    mkdir -p "$STATE_DIR"
    stage "Writing install record"
    printf '{\n  "installer_version": "%s",\n  "machine": "%s",\n  "pid": "%s",\n  "mode": "%s",\n  "web_ui": "%s",\n  "touchscreen": "%s",\n  "rootfs_sha256": "%s",\n  "backup": "%s",\n  "installed_utc": "%s"\n}\n' \
        "$INSTALLER_VERSION" "$MACHINE" "$PID" "$MODE" "$WEB" "$TOUCHSCREEN" "$image_hash" \
        "$BACKUP_TARGET" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL_STATE.tmp"
    mv "$INSTALL_STATE.tmp" "$INSTALL_STATE"
    sync
    progress "$total" "$total"
    stage "OpenCreator installation complete"
}
# Restores the newest backup. Archives may be rooted at / (backup_folders)
# or at the folder's parent (oc_backup_and_remove), so check the first entry.
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
        archive=$LATEST_BACKUP/$(printf '%s' "$folder" | tr / _).tar.gz
        if [ -f "$archive" ]; then
            first=$(tar -tzf "$archive" | head -n 1) || die "backup archive unreadable: ${archive##*/}"
            case "$first" in
                usr/*) dest=${DEMO_ROOT:-/} ;;
                *) dest=$DEMO_ROOT/${folder%/*} ;;
            esac
            stage "Restoring /$folder"
            rm -rf "$DEMO_ROOT/$folder"
            mkdir -p "$dest"
            tar -C "$dest" -xzf "$archive" || die "restore failed: /$folder"
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

case "$ACTION" in
    check) check ;;
    rootfs) update_rootfs ;;
    install) install_payload ;;
    restore) restore_backup ;;
    *) die "unknown action" ;;
esac
