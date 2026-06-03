# Maintainer: Brian <brian@krypton-lang.org>
pkgname=kryoterm
pkgver=0.1.0
pkgrel=1
pkgdesc="Krypton-native terminal emulator (no Qt, no GTK, no libX11 — speaks the X11 wire protocol directly)"
arch=('x86_64' 'aarch64')
url="https://github.com/t3m3d/kryoterm"
license=('MIT')
depends=()                          # static syscall-only ELF
makedepends=('git')                 # plus krypton (see below)
source=("git+$url.git#branch=main")
sha256sums=('SKIP')

_find_kcc() {
    if [[ -n "${KRYPTON_ROOT:-}" && -x "$KRYPTON_ROOT/kcc.sh" ]]; then
        echo "$KRYPTON_ROOT/kcc.sh"; return
    fi
    if command -v kcc.sh >/dev/null 2>&1; then
        command -v kcc.sh; return
    fi
    if [[ -x /opt/krypton/kcc.sh ]]; then
        echo /opt/krypton/kcc.sh; return
    fi
    echo "PKGBUILD: cannot find kcc.sh — set KRYPTON_ROOT to your krypton checkout" >&2
    return 1
}

build() {
    cd "$srcdir/$pkgname"
    local kcc; kcc=$(_find_kcc) || return 1
    msg2 "compiling via $kcc"
    "$kcc" -o "$srcdir/kryoterm" run.k
}

package() {
    install -Dm755 "$srcdir/kryoterm" "$pkgdir/usr/bin/kryoterm"
    install -Dm644 "$srcdir/$pkgname/LICENSE" \
        "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    install -Dm644 "$srcdir/$pkgname/README.md" \
        "$pkgdir/usr/share/doc/$pkgname/README.md"
}
