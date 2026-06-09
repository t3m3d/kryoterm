#!/usr/bin/env bash
# build_app.sh — assemble stem.app (Finder-launchable bundle).
#
# Wraps the temp Obj-C shim (stem-gui) + the pure-Krypton engine (stem)
# into a .app with an Info.plist, so stem has a real name/icon in the Dock,
# menu bar, and Spotlight. The shim finds the engine next to itself in
# Contents/MacOS, so no cwd assumptions.
set -euo pipefail
cd "$(dirname "$0")"

APP="stem.app"

[ -x stem-gui ] || ./build_gui.sh
[ -x stem ] || { echo "build_app.sh: ./stem missing — build it first:"; \
                     echo "  kcc --native run.k -o stem  (then codesign -s - -f stem)"; exit 1; }

[ -f stem.icns ] || ./make_icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp stem-gui stem "$APP/Contents/MacOS/"
cp stem.icns "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>stem</string>
  <key>CFBundleDisplayName</key>       <string>stem</string>
  <key>CFBundleExecutable</key>        <string>stem-gui</string>
  <key>CFBundleIconFile</key>          <string>stem</string>
  <key>CFBundleIdentifier</key>        <string>org.krypton.stem</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc sign the nested binaries, then the bundle.
codesign -s - -f "$APP/Contents/MacOS/stem" >/dev/null 2>&1 || true
codesign -s - -f "$APP/Contents/MacOS/stem-gui" >/dev/null 2>&1 || true
codesign -s - -f "$APP" >/dev/null 2>&1 || true

echo "built $APP — double-click in Finder, or:  open $APP"
