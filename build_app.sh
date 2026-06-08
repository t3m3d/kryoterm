#!/usr/bin/env bash
# build_app.sh — assemble kryoterm.app (Finder-launchable bundle).
#
# Wraps the temp Obj-C shim (kryoterm-gui) + the pure-Krypton engine (kryoterm)
# into a .app with an Info.plist, so kryoterm has a real name/icon in the Dock,
# menu bar, and Spotlight. The shim finds the engine next to itself in
# Contents/MacOS, so no cwd assumptions.
set -euo pipefail
cd "$(dirname "$0")"

APP="kryoterm.app"

[ -x kryoterm-gui ] || ./build_gui.sh
[ -x kryoterm ] || { echo "build_app.sh: ./kryoterm missing — build it first:"; \
                     echo "  kcc --native run.k -o kryoterm  (then codesign -s - -f kryoterm)"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp kryoterm-gui kryoterm "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>kryoterm</string>
  <key>CFBundleDisplayName</key>       <string>kryoterm</string>
  <key>CFBundleExecutable</key>        <string>kryoterm-gui</string>
  <key>CFBundleIdentifier</key>        <string>org.krypton.kryoterm</string>
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
codesign -s - -f "$APP/Contents/MacOS/kryoterm" >/dev/null 2>&1 || true
codesign -s - -f "$APP/Contents/MacOS/kryoterm-gui" >/dev/null 2>&1 || true
codesign -s - -f "$APP" >/dev/null 2>&1 || true

echo "built $APP — double-click in Finder, or:  open $APP"
