#!/usr/bin/env bash
# build_windows.sh — build stem on Windows (x86_64).
#
# Pure-Krypton + Win32 path: kcc compiles stem_win.ks to a native PE
# linked against the existing IAT thunks (user32, gdi32, comctl32,
# kernel32, dwmapi).  No gcc / cmake / clang.  After kcc emits the PE,
# we patch the IMAGE_OPTIONAL_HEADER.Subsystem byte CUI(3) -> GUI(2) so
# Explorer launches don't show a console window — kcc currently lacks
# a --subsystem flag, so the patch is the workaround.
#
# Usage:
#   ./build_windows.sh             # builds ./stem.exe from stem_win.ks
#   ./build_windows.sh --run       # ... then launches it once
#
# Requires:
#   kcc.exe on PATH or at C:\krypton\kcc.exe
#   python3 (for the PE subsystem byte patch)
#
# Pair / lineage:
#   run.k          — macOS PTY core (cocoa.k)
#   stem_win.ks    — this Windows port (gui.k, RichEdit-as-terminal)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KCC="${KCC:-$(command -v kcc.exe || echo "C:/krypton/kcc.exe")}"
OUT="${ROOT}/stem.exe"
MANIFEST="${ROOT}/stem_win.exe.manifest"

if [ ! -x "$KCC" ]; then
    echo "kcc.exe not found at $KCC; set KCC env var" >&2
    exit 1
fi

echo "[1/3] kcc compile -> $OUT"
"$KCC" "$ROOT/stem_win.ks" -o "$OUT"

echo "[2/3] patch PE Subsystem CUI->GUI"
python3 - <<PY
import struct, pathlib
p = pathlib.Path(r"$OUT")
with p.open('r+b') as f:
    f.seek(0x3c); off = struct.unpack('<I', f.read(4))[0]
    f.seek(off); assert f.read(4) == b'PE\x00\x00', 'bad PE sig'
    f.seek(off + 24 + 0x44); f.write(struct.pack('<H', 2))
print('  subsystem -> 2 (Windows GUI)')
PY

echo "[3/3] copy manifest sidecar"
cp "$MANIFEST" "$OUT.manifest"
echo "  $OUT.manifest"

echo ""
echo "OK -> $OUT"

if [ "${1:-}" = "--run" ]; then
    "$OUT"
fi
