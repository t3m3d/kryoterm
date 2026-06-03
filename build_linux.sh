#!/usr/bin/env bash
# build_linux.sh — build kryoterm on Linux (x86_64 / aarch64).
#
# Pure-Krypton build path: kcc.sh compiles run.k to a static,
# syscall-only ELF. No gcc / cmake / clang invocation at user-build
# time — once kcc itself is bootstrapped (one-time, in the krypton
# repo), every kryoterm rebuild is pure-Krypton.
#
# Usage:
#   ./build_linux.sh             # builds ./kryoterm from run.k
#   ./build_linux.sh --run       # ... then runs it once
#   ./build_linux.sh --ks        # builds the KryptScript entry instead
#                                # (run.ks → ./kryoterm)

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KRYPTON_ROOT="${KRYPTON_ROOT:-$SCRIPT_DIR/../krypton}"

if [[ ! -x "$KRYPTON_ROOT/kcc.sh" ]]; then
    echo "build_linux.sh: cannot find $KRYPTON_ROOT/kcc.sh" >&2
    echo "  Set KRYPTON_ROOT to your krypton checkout, e.g." >&2
    echo "    KRYPTON_ROOT=/path/to/krypton ./build_linux.sh" >&2
    exit 1
fi

SRC="$SCRIPT_DIR/run.k"
RUN=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        --ks)  SRC="$SCRIPT_DIR/run.ks" ;;
        -h|--help)
            grep '^#' "${BASH_SOURCE[0]}" | sed 's|^# \?||'
            exit 0 ;;
        *)
            echo "build_linux.sh: unknown arg '$arg'" >&2
            exit 1 ;;
    esac
done

OUT="$SCRIPT_DIR/kryoterm"

echo "build_linux.sh: $SRC -> $OUT (via $KRYPTON_ROOT/kcc.sh)"
"$KRYPTON_ROOT/kcc.sh" -o "$OUT" "$SRC"

if [[ ! -x "$OUT" ]]; then
    echo "build_linux.sh: build failed — $OUT not produced" >&2
    exit 1
fi

size=$(stat -c '%s' "$OUT" 2>/dev/null || wc -c <"$OUT")
echo "build_linux.sh: built ${OUT} (${size} bytes, static ELF)"

if [[ $RUN -eq 1 ]]; then
    exec "$OUT"
fi
