# Shared helpers for payload-template/*.sh: back up and replace a
# directory with a fresh shallow git clone, or a downloaded GitHub
# release asset. Sourced (". install-helpers.sh"), not executed.

# oc_backup_and_remove DIR
# If DIR exists, tar it into $OC_BACKUP, then remove it, so the caller
# can install fresh at the same path. No-op if DIR doesn't exist.
oc_backup_and_remove() {
    local dir=$1 name
    [ -e "$dir" ] || return 0
    : "${OC_BACKUP:?}"
    name=$(printf '%s' "$dir" | sed 's#^/##; s#/#_#g')
    echo "STAGE Backing up existing $dir"
    mkdir -p "$OC_BACKUP"
    tar -C "$(dirname "$dir")" -czf "$OC_BACKUP/$name.tar.gz.tmp" "$(basename "$dir")" \
        || { echo "ERROR backup of $dir failed"; exit 1; }
    mv "$OC_BACKUP/$name.tar.gz.tmp" "$OC_BACKUP/$name.tar.gz"
    rm -rf "$dir"
}

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
