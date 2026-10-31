# Shared helpers for payload-template/*.sh: a fresh shallow git clone,
# a downloaded GitHub release asset, and progress for long commands.
# Sourced (". install-helpers.sh"), not executed.

# What the installer calls the Python it installs
if [ "${OC_MACHINE:-}" = AD5X ]; then
    PYNAME="updated Python"
    PYCAP="Updated Python"
else
    PYNAME="hard-float Python"
    PYCAP="Hard-float Python"
fi

# The folder the installed files live in
if [ "${OC_MACHINE:-}" = AD5X ]; then
    OC_HOME=/usr/data/openad5x
else
    OC_HOME=/usr/data/opencreator
fi

# oc_git_clone_shallow URL DEST [BRANCH]
# Depth-1 clone: just the latest commit, not the whole history, so
# repeated installs don't fill up the printer's limited storage.
oc_git_clone_shallow() {
    local url=$1 dest=$2 branch=${3:-}
    echo "STAGE Cloning $url -> $dest (depth 1)"
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    if [ -n "$branch" ]; then
        git clone --depth 1 --branch "$branch" --single-branch "$url" "$dest"
    else
        git clone --depth 1 --single-branch "$url" "$dest"
    fi
}

# oc_github_latest_asset_url OWNER/REPO ASSET_NAME
# Prints the browser_download_url of the exact-named asset from that
# repo's latest release. Empty output (and nonzero exit) if not found.
# GitHub's API response has one key:value per line (pretty-printed, or
# minified-then-comma-split either way), each indented -- matching with
# a trailing-anchored regex rather than exact equality so leading
# whitespace doesn't matter. Each asset's "name" reliably precedes its
# own "browser_download_url" with no other asset's "name" in between.
oc_github_latest_asset_url() {
    local repo=$1 asset=$2
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | tr ',' '\n' \
        | awk -v asset="$asset" '
            /"name":/ {
                line = $0
                sub(/^.*"name": *"/, "", line)
                sub(/".*$/, "", line)
                inasset = (line == asset)
            }
            inasset && /"browser_download_url":/ {
                sub(/.*"browser_download_url": *"/, "");
                sub(/".*/, "");
                print;
                exit
            }
        '
}

# oc_download URL DEST
oc_download() {
    local url=$1 dest=$2
    mkdir -p "$(dirname "$dest")"
    curl -fsSL -o "$dest" "$url"
}

# oc_run_staged CMD [ARGS...]
# Runs CMD with its output passed through, and repeats pip/opkg progress
# lines as STAGE lines so the installer screen shows what is being worked
# on. Returns CMD's exit status.
oc_run_staged() {
    local rcfile rc
    rcfile=$(mktemp "${TMPDIR:-/tmp}/oc-rc.XXXXXX")
    { "$@" 2>&1 && echo 0 > "$rcfile" || echo $? > "$rcfile"; } |
        while IFS= read -r line; do
            printf '%s\n' "$line"
            case "$line" in
                Collecting*|"Building wheel for"*|"Installing collected packages"*|\
"Installing "*" to root"*|"Configuring "*)
                    printf 'STAGE %.120s\n' "$line" ;;
            esac
        done
    rc=$(cat "$rcfile" 2>/dev/null)
    rm -f "$rcfile"
    return "${rc:-1}"
}

# oc_swap_on / oc_swap_off
# A temporary 512 MB swap file on /usr/data while pip compiles, so the
# printer's 473 MB of RAM does not run out. Best effort: skipped if swap
# is already on or mkswap/swapon are missing, and the kernel's support is
# tried with a 1 MB file before 512 MB are written. A failure is remembered
# in OC_SWAP_BROKEN so later installs don't try again.
OC_SWAPFILE=$OC_HOME/swapfile
OC_SWAP_BROKEN=$OC_HOME/.swap-unsupported
oc_swap_on() {
    [ -z "${OC_DEMO_ROOT:-}" ] || return 0
    command -v mkswap >/dev/null 2>&1 && command -v swapon >/dev/null 2>&1 || return 0
    [ ! -f "$OC_SWAP_BROKEN" ] || return 0
    [ -r /proc/swaps ] || { : > "$OC_SWAP_BROKEN"; return 0; }
    [ "$(awk 'NR > 1' /proc/swaps | wc -l)" -eq 0 ] || return 0
    mkdir -p "$(dirname "$OC_SWAPFILE")"
    if ! { dd if=/dev/zero of="$OC_SWAPFILE" bs=1M count=1 2>/dev/null &&
        chmod 600 "$OC_SWAPFILE" && mkswap "$OC_SWAPFILE" >/dev/null 2>&1 &&
        swapon "$OC_SWAPFILE" 2>/dev/null; }; then
        rm -f "$OC_SWAPFILE"
        : > "$OC_SWAP_BROKEN"
        echo "STAGE Swap is not supported on this printer; continuing without it"
        return 0
    fi
    swapoff "$OC_SWAPFILE" 2>/dev/null || true
    echo "STAGE Adding temporary swap for compiling"
    dd if=/dev/zero of="$OC_SWAPFILE" bs=1M count=512 2>/dev/null &&
        mkswap "$OC_SWAPFILE" >/dev/null 2>&1 && swapon "$OC_SWAPFILE" 2>/dev/null ||
        { echo "STAGE Temporary swap unavailable; continuing without it"; rm -f "$OC_SWAPFILE"; }
}
oc_swap_off() {
    [ -f "$OC_SWAPFILE" ] || return 0
    swapoff "$OC_SWAPFILE" 2>/dev/null || true
    rm -f "$OC_SWAPFILE"
}

# oc_overlay SRC DEST MANIFEST [nosave]
# Copies SRC's files over DEST and keeps every other file in DEST (user
# additions). MANIFEST records "md5  path" for what was installed: a file
# listed there that SRC no longer has is removed only if it is unchanged.
# A file the user changed is saved under $OC_BACKUP/overlay before it is
# replaced (not with nosave, for build output like the web UIs).
oc_overlay() {
    local src=$1 dest=$2 manifest=$3 save=${4:-save} new f sum
    new=$manifest.new
    mkdir -p "$dest" "$(dirname "$manifest")"
    : > "$new"
    (cd "$src" && find . -type f | sed 's#^\./##') | while IFS= read -r f; do
        if [ "$save" = save ] && [ -f "$dest/$f" ] && ! cmp -s "$src/$f" "$dest/$f"; then
            sum=$(md5sum < "$dest/$f" | cut -d' ' -f1)
            if ! grep -qx "$sum  $f" "$manifest" 2>/dev/null; then
                mkdir -p "$OC_BACKUP/overlay$dest/$(dirname "$f")"
                cp -p "$dest/$f" "$OC_BACKUP/overlay$dest/$f"
                echo "STAGE Saved your changed $dest/$f to the backup"
            fi
        fi
        mkdir -p "$dest/$(dirname "$f")"
        cp -p "$src/$f" "$dest/$f.oc-new" && mv "$dest/$f.oc-new" "$dest/$f"
        echo "$(md5sum < "$src/$f" | cut -d' ' -f1)  $f" >> "$new"
    done
    if [ -f "$manifest" ]; then
        while IFS= read -r line; do
            f=${line#*  }
            [ -f "$src/$f" ] || [ ! -f "$dest/$f" ] && continue
            [ "$(md5sum < "$dest/$f" | cut -d' ' -f1)  $f" = "$line" ] && rm -f "$dest/$f"
        done < "$manifest"
    fi
    mv "$new" "$manifest"
    return 0
}

# sha256_of FILE: prints the hash. The first tool that prints a real hash wins: a sha256sum
# on PATH can be a broken link or applet left by another mod.
sha256_of() {
    for tool in sha256sum "busybox sha256sum" /opt/bin/sha256sum ff-openssl openssl; do
        case $tool in
            ff-openssl) out=$(LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib \
                /usr/prog/openssl-1.0.2d/bin/openssl dgst -sha256 < "$1" 2>/dev/null | sed 's/^.*= *//') ;;
            openssl) out=$(openssl dgst -sha256 < "$1" 2>/dev/null | sed 's/^.*= *//') ;;
            *) out=$($tool < "$1" 2>/dev/null | cut -d' ' -f1) ;;
        esac
        case $out in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ ${#out} -eq 64 ] && { echo "$out"; return 0; } ;;
        esac
    done
    return 1
}
