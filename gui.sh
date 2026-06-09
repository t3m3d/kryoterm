#!/usr/bin/env bash
# gui.sh — run stem in its Cocoa window. The terminal engine is pure Krypton
# (run.k -i: pty + ANSI grid + colour + UTF-8 + interactive bridge); stem-gui
# is the temporary Obj-C window shim, which spawns `stem -i` on a pty, draws
# its frames, and forwards keystrokes. Builds whatever's missing.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$SCRIPT_DIR/stem-gui" ]] || "$SCRIPT_DIR/build_gui.sh"
[[ -x "$SCRIPT_DIR/stem" ]] || "$SCRIPT_DIR/build.sh"
exec "$SCRIPT_DIR/stem-gui" "$SCRIPT_DIR/stem"
