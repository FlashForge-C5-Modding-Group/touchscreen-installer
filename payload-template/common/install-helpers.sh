# Shared helpers for payload-template/*.sh: a fresh shallow git clone,
# a downloaded GitHub release asset, and progress for long commands.
# Sourced (". install-helpers.sh"), not executed.

# oc_set_clock
# HTTPS downloads fail with "certificate is not yet valid" while the clock is
# still near 1970. Try NTP, then the time protocol, then the Date header of a
# plain HTTP reply (port 80 gets through where NTP and rdate are blocked).
# Never leave the clock earlier than this payload's build-date.
OC_NTP_SERVERS="pool.ntp.org time.google.com time.cloudflare.com time.apple.com
time.windows.com 0.pool.ntp.org 1.pool.ntp.org ntp.aliyun.com ntp.tencent.com
time.nist.gov"
OC_RDATE_SERVERS="time.nist.gov time-a-g.nist.gov time-b-g.nist.gov time-a-wwv.nist.gov"
OC_DATE_URLS="http://bin.entware.net/ http://github.com/ http://www.google.com/
http://www.cloudflare.com/ http://www.baidu.com/ http://www.microsoft.com/"

# The Date header of URL as "YYYY-MM-DD HH:MM:SS" (UTC), or nothing.
oc_url_date() {
    { /opt/bin/curl -sI -m 6 "$1" 2>/dev/null || wget -S -q -O /dev/null -T 6 "$1" 2>&1; } |
        tr -d '\r' | sed -n 's/^ *[Dd]ate: *[A-Za-z]*, *//p' | head -n 1 |
        awk '{ m = index("JanFebMarAprMayJunJulAugSepOctNovDec", $2)
               if (m && $3 >= 2024)
                   printf "%04d-%02d-%02d %s\n", $3, (m + 2) / 3, $1, $4 }'
}

# oc_race DIR SECS PIDS...: wait until an attempt has written DIR/ok, every
# attempt (PIDS) has ended, or SECS pass; then stop the rest. busybox ntpd -q
# retries forever when port 123 is silently dropped.
oc_race() {
    local dir=$1 secs=$2 i=0 pid alive
    shift 2
    while [ "$i" -lt $((secs * 4)) ] && [ ! -s "$dir/ok" ]; do
        alive=
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && { alive=1; break; }; done
        [ -n "$alive" ] || break
        sleep 0.25 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    cat "$dir"/pid.* 2>/dev/null | xargs kill 2>/dev/null
    kill "$@" 2>/dev/null
    rm -f "$dir"/pid.*
    [ -s "$dir/ok" ]
}

oc_set_clock() {
    local how= stamp floor server url n=0 dir pids=
    dir=${TMPDIR:-/tmp}/oc-clock.$$
    rm -rf "$dir"; mkdir -p "$dir"
    # Every NTP and Time-protocol server at once: the first answer sets the clock
    echo "STAGE Asking $(echo $OC_NTP_SERVERS $OC_RDATE_SERVERS | wc -w) time servers"
    for server in $OC_NTP_SERVERS; do
        n=$((n + 1))
        ( busybox ntpd -n -q -p "$server" >/dev/null 2>&1 & echo $! > "$dir/pid.$n"
          wait $! && echo "NTP ($server)" >> "$dir/ok" ) 2>/dev/null &
        pids="$pids $!"
    done
    for server in $OC_RDATE_SERVERS; do
        n=$((n + 1))
        ( rdate -s "$server" >/dev/null 2>&1 & echo $! > "$dir/pid.$n"
          wait $! && echo "time server ($server)" >> "$dir/ok" ) 2>/dev/null &
        pids="$pids $!"
    done
    oc_race "$dir" 8 $pids && how=$(head -n 1 "$dir/ok")
    if [ -z "$how" ]; then
        # Port 80 gets through where NTP (UDP 123) and TCP 37 are blocked
        echo "STAGE No time server answered; reading the date from web servers"
        pids=
        for url in $OC_DATE_URLS; do
            ( stamp=$(oc_url_date "$url") && [ -n "$stamp" ] &&
                echo "$stamp $url" >> "$dir/ok" ) 2>/dev/null &
            pids="$pids $!"
        done
        if oc_race "$dir" 8 $pids; then
            stamp=$(head -n 1 "$dir/ok")
            url=${stamp#* * }
            date -u -s "${stamp%" $url"}" >/dev/null 2>&1 && how="web server date ($url)"
        fi
    fi
    rm -rf "$dir"
    floor=$(head -n 1 "${OC_PAYLOAD:-${PAYLOAD:-}}/build-date" 2>/dev/null) || floor=
    if [ -n "$floor" ] && [ "$(date -u +%s)" -lt "$(date -u -d "$floor" +%s 2>/dev/null || echo 0)" ]; then
        date -u -s "$floor" >/dev/null 2>&1 && how="${how:+$how, raised to }installer build date"
    fi
    if [ -n "$how" ]; then
        echo "STAGE Clock set from $how: $(date -u '+%Y-%m-%d %H:%M UTC')"
    else
        echo "WARN Could not set the clock; HTTPS downloads may fail. Set it with: date -s \"YYYY-MM-DD HH:MM:SS\""
        return 1
    fi
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
