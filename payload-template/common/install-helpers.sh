# Shared helpers for payload-template/*.sh: a fresh shallow git clone,
# a downloaded GitHub release asset, and progress for long commands.
# Sourced (". install-helpers.sh"), not executed.

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
# is already on or mkswap/swapon are missing.
OC_SWAPFILE=/usr/data/opencreator/swapfile
oc_swap_on() {
    [ -z "${OC_DEMO_ROOT:-}" ] || return 0
    command -v mkswap >/dev/null 2>&1 && command -v swapon >/dev/null 2>&1 || return 0
    [ "$(awk 'NR > 1' /proc/swaps | wc -l)" -eq 0 ] || return 0
    echo "STAGE Adding temporary swap for compiling"
    mkdir -p "$(dirname "$OC_SWAPFILE")"
    dd if=/dev/zero of="$OC_SWAPFILE" bs=1M count=512 2>/dev/null &&
        chmod 600 "$OC_SWAPFILE" && mkswap "$OC_SWAPFILE" >/dev/null 2>&1 &&
        swapon "$OC_SWAPFILE" 2>/dev/null ||
        { echo "STAGE Temporary swap unavailable; continuing without it"; rm -f "$OC_SWAPFILE"; }
}
oc_swap_off() {
    [ -f "$OC_SWAPFILE" ] || return 0
    swapoff "$OC_SWAPFILE" 2>/dev/null || true
    rm -f "$OC_SWAPFILE"
}
