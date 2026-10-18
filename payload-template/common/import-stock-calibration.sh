#!/bin/sh
# import-stock-calibration.sh STOCK_CFG OPENCREATOR_CFG
# First installs: the printer's own calibration from FlashForge's printer.cfg
# (its SAVE_CONFIG block: input shaper, hotend and bed PID) replaces the same
# sections in the new OpenCreator printer.cfg; sections only FlashForge has
# are added. The bed mesh is left out: OpenCreator measures its own.
set -eu
STOCK=$1
TARGET=$2
MARK='^#\*# <-* SAVE_CONFIG -*>'

if [ ! -f "$STOCK" ] || ! grep -q "$MARK" "$STOCK"; then
    echo "STAGE No FlashForge calibration to import"
    exit 0
fi
[ -f "$TARGET" ] || { echo "ERROR $TARGET missing"; exit 1; }
grep -q "$MARK" "$TARGET" ||
    printf '\n#*# <---------------------- SAVE_CONFIG ---------------------->\n#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.\n#*#\n' >>"$TARGET"

tr -d '\r' <"$STOCK" >"$TARGET.stock"
tr -d '\r' <"$TARGET" >"$TARGET.cur"
awk '
    # Sections of a SAVE_CONFIG block: name -> lines (from "#*# [name]" up to
    # the next section; the "#*#" separators are written fresh).
    function add(src, name, line) {
        if (!((src, name) in text)) { order[src, ++count[src]] = name }
        text[src, name] = text[src, name] line "\n"
    }
    FNR == 1 { src++; inblock = 0; name = "" }
    {
        if (!inblock) {
            if ($0 ~ /^#\*# <-* SAVE_CONFIG -*>/) { inblock = 1; if (src == 2) head = head $0 "\n" }
            else if (src == 2) body = body $0 "\n"
            next
        }
        if ($0 ~ /^#\*# \[.*\]$/) { name = substr($0, 6, length($0) - 6) }
        if (name == "") { if (src == 2 && $0 != "#*#") head = head $0 "\n"; next }
        if ($0 == "#*#") next
        add(src, name, $0)
    }
    END {
        printf "%s%s#*#\n", body, head
        for (i = 1; i <= count[2]; i++) {
            n = order[2, i]
            if ((1, n) in text && n !~ /^bed_mesh/) { printf "%s#*#\n", text[1, n]; done[n] = 1; imported = imported " " n }
            else printf "%s#*#\n", text[2, n]
        }
        for (i = 1; i <= count[1]; i++) {
            n = order[1, i]
            if (!(n in done) && n !~ /^bed_mesh/) { printf "%s#*#\n", text[1, n]; imported = imported " " n }
        }
        print imported > "/dev/stderr"
    }
' "$TARGET.stock" "$TARGET.cur" >"$TARGET.new" 2>"$TARGET.imported"
imported=$(cat "$TARGET.imported")
if [ -s "$TARGET.new" ] && grep -q "$MARK" "$TARGET.new"; then
    mv "$TARGET.new" "$TARGET"
    echo "STAGE Imported FlashForge calibration:${imported:- nothing}"
else
    echo "WARN Could not import FlashForge's calibration; printer.cfg left as it was"
fi
rm -f "$TARGET.stock" "$TARGET.cur" "$TARGET.new" "$TARGET.imported"
