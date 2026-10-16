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
INSTALLER_VERSION=0.3.0
MIN_FREE_KB=${OC_MIN_FREE_KB:-262144}
BACKUP_FOLDERS="usr/prog/PROGRAM usr/prog/moonraker usr/data/opencreator
usr/data/mainsail usr/data/fluidd usr/data/nginx usr/prog/c5-tunnel-socat
usr/prog/logo.jpeg usr/prog/app_startup.sh"

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
    if [ -z "$DEMO_ROOT" ] && ! ping -c1 -W3 github.com >/dev/null 2>&1; then
        warn "No internet: the install downloads Entware and the rest, connect Wi-Fi first"
    fi
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
    if latest_backup; then printf 'BACKUP %s\n' "$LATEST_BACKUP"; fi
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
    for folder in $BACKUP_FOLDERS; do
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
    [ "$MODE" != soc ] || [ "$WEB" != none ] || die "SoC mode requires a web UI"
    detect_model || die "unsupported or undetected printer model"
    stage "Detected $MACHINE (PID $PID)"
    missing_tools=
    for tool in tar gzip gunzip md5sum sed grep awk find mktemp wget od dd; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools="$missing_tools $tool"
    done
    [ -z "$missing_tools" ] || die "the printer is missing:$missing_tools; nothing was changed"
    kernel_supported || die "unsupported FlashForge kernel package $KERNEL_PACKAGE (legacy NaN address unknown)"
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
        # Payload steps still keep small "previous" copies here.
        BACKUP_TARGET=$STATE_DIR/no-backup
        mkdir -p "$BACKUP_TARGET"
        RECORDED_BACKUP=none
    else
        backup_folders
        RECORDED_BACKUP=$BACKUP_TARGET
    fi
    n=1
    progress "$n" "$total"
    for script in "$scripts"/*.sh; do
        [ -f "$script" ] || continue
        n=$((n + 1))
        stage "Running ${script##*/}"
        OC_PAYLOAD="$PAYLOAD" OC_MODE="$MODE" OC_WEB_UI="$WEB" \
            OC_TOUCHSCREEN="$TOUCHSCREEN" OC_MACHINE="$MACHINE" OC_PID="$PID" \
            OC_KERNEL_PACKAGE="$KERNEL_PACKAGE" OC_NAN_ADDR="$NAN_ADDR" \
            OC_BACKUP="$BACKUP_TARGET" /bin/sh "$script" || die "failed: ${script##*/}"
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
        OC_BACKUP="$BACKUP_TARGET" OC_KEEP_WEB=1 /bin/sh "$PAYLOAD/$1" || die "failed: ${1##*/}"
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
            steps="installers/soc/01-install-entware.sh installers/soc/02-install-loopscript.sh"
            [ -f "$OC/klipper/klipper/klippy/klippy.py" ] && [ -x "$OC/klipper/klippy-env/bin/python" ] ||
                steps="$steps installers/soc/10-install-stack.sh"
            # Tunnel installs leave FlashForge's own Moonraker in place.
            git -C "$MR/moonraker" remote get-url origin 2>/dev/null | grep -q Arksine &&
                [ -x "$MR/moonraker-env/bin/python" ] ||
                steps="$steps installers/soc/15-install-moonraker.sh"
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

case "$ACTION" in
    check) check ;;
    install) install_payload ;;
    reconfigure) reconfigure ;;
    restore) restore_backup ;;
    *) die "unknown action" ;;
esac
