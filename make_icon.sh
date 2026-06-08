#!/usr/bin/env bash
# make_icon.sh — render kryoterm.icns from make_icon.m (each size drawn crisp).
set -euo pipefail
cd "$(dirname "$0")"

clang -framework Cocoa -fobjc-arc -O2 -w make_icon.m -o make_icon

ICONSET=/tmp/kryoterm.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
while read -r sz name; do
  [ -n "$sz" ] && ./make_icon "$ICONSET/$name" "$sz" 2>/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

iconutil -c icns "$ICONSET" -o kryoterm.icns
echo "built kryoterm.icns ($(du -h kryoterm.icns | cut -f1))"
