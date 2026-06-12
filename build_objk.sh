#!/usr/bin/env bash
# build_objk.sh — build the PURE-KRYPTON kryoterm GUI (objk FFI). No Obj-C source.
#
# This replaces the temporary clang shim (build_gui.sh / gui_shim.m): the window,
# the custom NSView drawRect grid, keyDown->pty, and the NSTimer/pump event loop
# are all written in Krypton (kryoterm.ks) on the objk Objective-C FFI. The only
# things linked are the system dylibs libobjc + Foundation + AppKit — verify with
# `otool -L dist/kryoterm.app/Contents/MacOS/kryoterm`.
#
# Requires the Krypton dev tree (the objk FFI is newer than the released kcc):
#   - compiler/macos_arm64/kcc-arm64   (IR frontend)
#   - compiler/macos_arm64/macho_host  (macho codegen, rebuilt from the backend)
#   - stdlib/cocoa.k + stdlib/objc.k + headers/cocoa.krh + headers/objc.krh
# Point KRYPTON_ROOT at that checkout (default: a sibling ../krypton).
set -euo pipefail
cd "$(dirname "$0")"

KRYPTON_ROOT="${KRYPTON_ROOT:-$(cd .. && pwd)/krypton}"
SRC="kryoterm.ks"
NAME="kryoterm"

if [ ! -d "$KRYPTON_ROOT/stdlib" ] || [ ! -x "$KRYPTON_ROOT/compiler/macos_arm64/kcc-arm64" ]; then
  echo "build_objk.sh: KRYPTON_ROOT='$KRYPTON_ROOT' is not a Krypton dev checkout." >&2
  echo "  set KRYPTON_ROOT=/path/to/krypton (needs compiler/macos_arm64 + stdlib + headers)" >&2
  exit 1
fi

FE="$KRYPTON_ROOT/compiler/macos_arm64/kcc-arm64"
HOST="$KRYPTON_ROOT/compiler/macos_arm64/macho_host"
BACKEND="$KRYPTON_ROOT/compiler/macos_arm64/macho_arm64_self.k"

# Ensure the macho codegen host is built from the current backend (objk lives here).
if [ ! -x "$HOST" ] || [ "$BACKEND" -nt "$HOST" ]; then
  echo "==> building macho_host from macho_arm64_self.k"
  kcc --native "$BACKEND" -o "$HOST"
fi

echo "==> compiling $SRC (objk, pure Krypton)"
KRYPTON_ROOT="$KRYPTON_ROOT" "$FE" "$SRC" > "/tmp/$NAME.kir"
"$HOST" --ir "/tmp/$NAME.kir" "/tmp/$NAME.bin" >/dev/null

APP="dist/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "/tmp/$NAME.bin" "$APP/Contents/MacOS/$NAME"
chmod +x "$APP/Contents/MacOS/$NAME"
[ -f kryoterm.icns ] && cp kryoterm.icns "$APP/Contents/Resources/$NAME.icns" || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>kryoterm</string>
  <key>CFBundleDisplayName</key><string>kryoterm</string>
  <key>CFBundleExecutable</key><string>kryoterm</string>
  <key>CFBundleIdentifier</key><string>org.krypton-lang.kryoterm</string>
  <key>CFBundleIconFile</key><string>kryoterm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST
codesign -s - -f "$APP/Contents/MacOS/$NAME" >/dev/null 2>&1 || true
codesign -s - -f "$APP" >/dev/null 2>&1 || true
echo "==> built $APP (pure Krypton, no Obj-C source). Run:  open $APP"
