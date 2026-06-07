#!/usr/bin/env bash
# gui.sh — run kryoterm in its Cocoa window. The terminal engine is pure Krypton
# (run.k: pty + ANSI grid + colour + UTF-8); kryoterm-gui is the temporary Obj-C
# window shim. Builds whatever's missing, then pipes the engine into the window.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$SCRIPT_DIR/kryoterm-gui" ]] || "$SCRIPT_DIR/build_gui.sh"
[[ -x "$SCRIPT_DIR/kryoterm" ]] || "$SCRIPT_DIR/build.sh"
exec "$SCRIPT_DIR/kryoterm" | "$SCRIPT_DIR/kryoterm-gui"
