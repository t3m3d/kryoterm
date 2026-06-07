#!/usr/bin/env bash
# build_gui.sh — compile the TEMPORARY kryoterm GUI shim (Obj-C/Cocoa).
# The terminal engine is pure Krypton; this only opens a window + draws.
# Delete once objc_msgSend FFI lands in the Krypton macho backend.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clang -framework Cocoa -fobjc-arc -O2 -Wall "$SCRIPT_DIR/gui_shim.m" -o "$SCRIPT_DIR/kryoterm-gui"
echo "build_gui.sh: built ./kryoterm-gui"
