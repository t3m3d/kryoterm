#!/usr/bin/env bash
# gui.sh — run kryoterm in its Cocoa window. The terminal engine is pure Krypton
# (run.k -i: pty + ANSI grid + colour + UTF-8 + interactive bridge); kryoterm-gui
# is the temporary Obj-C window shim, which spawns `kryoterm -i` on a pty, draws
# its frames, and forwards keystrokes. Builds whatever's missing.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$SCRIPT_DIR/kryoterm-gui" ]] || "$SCRIPT_DIR/build_gui.sh"
[[ -x "$SCRIPT_DIR/kryoterm" ]] || "$SCRIPT_DIR/build.sh"
exec "$SCRIPT_DIR/kryoterm-gui" "$SCRIPT_DIR/kryoterm"
