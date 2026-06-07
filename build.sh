#!/usr/bin/env bash
# build.sh — build kryoterm (macOS arm64 / Linux x86_64). Pure Krypton: the
# kcc driver compiles run.ks to a native, syscall-only binary. No gcc / clang /
# cmake at build time once kcc itself is installed.
#
# Usage:
#   ./build.sh             # build ./kryoterm from run.ks (the KryptScript entry)
#   ./build.sh --run       # ... then run it once
#   ./build.sh --k         # build run.k directly instead of run.ks
#
# kcc resolution: prefer `kcc` on PATH (e.g. `brew install t3m3d/krypton/krypton`),
# else the platform driver seed in a krypton checkout ($KRYPTON_ROOT, default
# ../krypton). kcc.sh was removed upstream — this uses the kcc.ks driver.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KRYPTON_ROOT="${KRYPTON_ROOT:-$SCRIPT_DIR/../krypton}"

case "$(uname -s)" in
    Darwin) SEED="kcc_driver_macos_aarch64" ;;
    *)      SEED="kcc_driver_linux_x86_64"  ;;
esac

if command -v kcc >/dev/null 2>&1; then
    KCC=(kcc)
elif [[ -x "$KRYPTON_ROOT/bootstrap/$SEED" ]]; then
    KCC=(env "KRYPTON_ROOT=$KRYPTON_ROOT" "$KRYPTON_ROOT/bootstrap/$SEED")
else
    echo "build.sh: no 'kcc' on PATH and no $KRYPTON_ROOT/bootstrap/$SEED" >&2
    echo "  Install Krypton (brew install t3m3d/krypton/krypton) or set" >&2
    echo "  KRYPTON_ROOT to a krypton checkout." >&2
    exit 1
fi

SRC="$SCRIPT_DIR/run.ks"
RUN=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        --k)   SRC="$SCRIPT_DIR/run.k" ;;
        -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed 's|^# \?||'; exit 0 ;;
        *)     echo "build.sh: unknown arg '$arg'" >&2; exit 1 ;;
    esac
done

OUT="$SCRIPT_DIR/kryoterm"
echo "build.sh: $SRC -> $OUT"
"${KCC[@]}" --native "$SRC" -o "$OUT"

# macOS: ad-hoc sign so AMFI lets the fresh binary run.
[[ "$(uname -s)" == "Darwin" ]] && codesign -s - -f "$OUT" >/dev/null 2>&1 || true

[[ -x "$OUT" ]] || { echo "build.sh: build failed — $OUT not produced" >&2; exit 1; }
echo "build.sh: built $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"

[[ $RUN -eq 1 ]] && exec "$OUT"
exit 0
