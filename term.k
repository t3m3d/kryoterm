// term.k — kryoterm grid driver (pure Krypton terminal core, phase 4).
//
// The next layer up from ansi.k: maintains a rows×cols character grid with a
// cursor and ACTS on the common VT sequences — cursor positioning
// (CUP/CUU/CUD/CUF/CUB), erase (ED/EL), CR/LF/BS/TAB, and SGR foreground COLOR
// — then renders the grid back to text (re-emitting ANSI color so the host
// terminal shows it). Krypton port of brain/terk's Grid + Terminal::applyEscape.
//
// Two parallel FLAT strings of rows*cols bytes (index = row*cols + col): `grid`
// holds the character, `attr` holds the cell's foreground SGR code (sentinel 1 =
// default). Uses only charCode/substring/len/sbAppend/fromCharCode — all
// verified-working native builtins (k:map is broken on macho). No C, no FFI, no
// maps. All state local to renderGrid (Krypton modules don't keep state across
// the import boundary). Note attr cells use byte 1 (SOH), never 0 (NUL), since
// Krypton string length is NUL-terminated.

module kryoterm_term

// _isLetter(code) — CSI final byte is an ASCII letter.
func _isLetter(c) {
    emit (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}

// _leadInt(s, def) — leading non-negative integer in s; `def` if none.
func _leadInt(s, def) {
    let n = len(s)
    let i = 0
    let v = 0
    let any = 0
    while i < n {
        let c = charCode(substring(s, i, i + 1))
        if c >= 48 && c <= 57 { v = v * 10 + (c - 48)  any = 1  i = i + 1 }
        else { i = n }
    }
    if any == 0 { emit def }
    emit v
}

// _afterSemi(s) — substring after the first ';' (empty if none). For ESC[r;cH.
func _afterSemi(s) {
    let n = len(s)
    let i = 0
    while i < n {
        if charCode(substring(s, i, i + 1)) == 59 { emit substring(s, i + 1, n) }
        i = i + 1
    }
    emit ""
}

// _clamp(v, lo, hi)
func _clamp(v, lo, hi) {
    if v < lo { emit lo }
    if v > hi { emit hi }
    emit v
}

// _blank(size) — a string of `size` spaces.
func _blank(size) {
    let sb = sbNew()
    let i = 0
    while i < size { sb = sbAppend(sb, " ")  i = i + 1 }
    emit sbToString(sb)
}

// _fill1(size) — a string of `size` SOH bytes (the default-foreground sentinel).
func _fill1(size) {
    let sb = sbNew()
    let one = fromCharCode(1)
    let i = 0
    while i < size { sb = sbAppend(sb, one)  i = i + 1 }
    emit sbToString(sb)
}

// _put(grid, idx, ch) — return grid with the char at flat index idx replaced.
func _put(grid, idx, ch) {
    emit substring(grid, 0, idx) + ch + substring(grid, idx + 1, len(grid))
}

// _scrollUp(g, cols, total, fillRow) — drop the top row, append a blank bottom
// row. Used when output runs past the last line (real terminal scrolling).
func _scrollUp(g, cols, total, fillRow) {
    emit substring(g, cols, total) + fillRow
}

// _applySgr(pen, params) — fold an SGR parameter list (e.g. "1;31;44") into the
// colour pen. The pen packs fg+bg as fg*256+bg (sentinel 1 = default for each).
// Handles reset (0 / empty), fg 30-37 / 39 / bright 90-97, bg 40-47 / 49 / bright
// 100-107; ignores bold/256-colour. Returns the new packed pen.
func _applySgr(pen, params) {
    let n = len(params)
    if n == 0 { emit 257 }               // ESC[m == ESC[0m == reset (fg=1,bg=1)
    let fg = pen / 256
    let bg = pen - fg * 256
    let i = 0
    let cur = 0
    let any = 0
    while i <= n {
        let sep = 0
        if i == n { sep = 1 }
        else { if charCode(substring(params, i, i + 1)) == 59 { sep = 1 } }
        if sep == 1 {
            if any == 1 {
                if cur == 0 { fg = 1  bg = 1 }
                if cur == 39 { fg = 1 }
                if cur >= 30 && cur <= 37 { fg = cur }
                if cur >= 90 && cur <= 97 { fg = cur }
                if cur == 49 { bg = 1 }
                if cur >= 40 && cur <= 47 { bg = cur }
                if cur >= 100 && cur <= 107 { bg = cur }
            }
            cur = 0
            any = 0
        } else {
            let c = charCode(substring(params, i, i + 1))
            if c >= 48 && c <= 57 { cur = cur * 10 + (c - 48)  any = 1 }
        }
        i = i + 1
    }
    emit fg * 256 + bg
}

// _sgrPair(fg, bg) — ANSI to set the host terminal to (fg,bg); 1 = default.
// Reset-then-set so no stale attribute leaks between cells.
func _sgrPair(fg, bg) {
    let e = fromCharCode(27)
    let s = e + "[0m"
    if fg != 1 { s = s + e + "[" + (fg + 0) + "m" }
    if bg != 1 { s = s + e + "[" + (bg + 0) + "m" }
    emit s
}

// renderGrid(s, cols, rows) — feed byte string s into a cols×rows grid, apply
// cursor/erase/colour sequences, return the grid as text (rows joined by \n,
// trailing spaces trimmed per row, foreground colour re-emitted as ANSI).
func renderGrid(s, cols, rows) {
    let total = cols * rows
    let grid = _blank(total)
    let attr = _fill1(total)               // per-cell fg code (1 = default)
    let battr = _fill1(total)              // per-cell bg code (1 = default)
    let pen = 257                          // packed fg*256+bg, default 1*256+1
    let cr = 0
    let cc = 0
    let n = len(s)
    let i = 0

    while i < n {
        let c = charCode(substring(s, i, i + 1))

        if c == 27 {                                   // ESC
            if i + 1 >= n { i = n }
            else {
                let k = charCode(substring(s, i + 1, i + 2))
                if k == 91 {                           // '[' → CSI
                    let j = i + 2
                    while j < n && _isLetter(charCode(substring(s, j, j + 1))) == 0 { j = j + 1 }
                    if j >= n { i = n }
                    else {
                        let fin = charCode(substring(s, j, j + 1))
                        let params = substring(s, i + 2, j)
                        let p0 = _leadInt(params, 1)
                        if fin == 72 || fin == 102 {     // 'H'/'f' CUP row;col (1-based)
                            cr = _clamp(p0 - 1, 0, rows - 1)
                            cc = _clamp(_leadInt(_afterSemi(params), 1) - 1, 0, cols - 1)
                        }
                        if fin == 65 { cr = _clamp(cr - p0, 0, rows - 1) }   // up
                        if fin == 66 { cr = _clamp(cr + p0, 0, rows - 1) }   // down
                        if fin == 67 { cc = _clamp(cc + p0, 0, cols - 1) }   // forward
                        if fin == 68 { cc = _clamp(cc - p0, 0, cols - 1) }   // back
                        if fin == 109 { pen = _applySgr(pen, params) }       // 'm' SGR colour
                        if fin == 74 {                   // 'J' erase display (2/3 = all)
                            if _leadInt(params, 0) >= 2 { grid = _blank(total)  attr = _fill1(total)  battr = _fill1(total)  cr = 0  cc = 0 }
                        }
                        if fin == 75 {                   // 'K' erase whole line
                            let st = cr * cols
                            grid = substring(grid, 0, st) + _blank(cols) + substring(grid, st + cols, total)
                            attr = substring(attr, 0, st) + _fill1(cols) + substring(attr, st + cols, total)
                            battr = substring(battr, 0, st) + _fill1(cols) + substring(battr, st + cols, total)
                        }
                        i = j + 1
                    }
                } else {
                    if k == 93 {                         // ']' → OSC: skip to BEL/ST
                        let j = i + 2
                        let done = 0
                        while j < n && done == 0 {
                            let cj = charCode(substring(s, j, j + 1))
                            if cj == 7 { done = 1  i = j + 1 }
                            else {
                                if cj == 27 && j + 1 < n && charCode(substring(s, j + 1, j + 2)) == 92 { done = 1  i = j + 2 }
                                else { j = j + 1 }
                            }
                        }
                        if done == 0 { i = n }
                    } else { i = i + 2 }                 // ESC x (2-byte)
                }
            }
        } else {
            if c == 10 {                                                         // LF → newline (col reset, matches brain)
                cr = cr + 1  cc = 0
                if cr >= rows {
                    grid = _scrollUp(grid, cols, total, _blank(cols))
                    attr = _scrollUp(attr, cols, total, _fill1(cols))
                    battr = _scrollUp(battr, cols, total, _fill1(cols))
                    cr = rows - 1
                }
                i = i + 1
            }
            else {
                if c == 13 { cc = 0  i = i + 1 }                                     // CR
                else {
                    if c == 8 { if cc > 0 { cc = cc - 1 }  i = i + 1 }               // BS
                    else {
                        if c == 9 {                                                  // TAB
                            cc = ((cc / 8) + 1) * 8
                            if cc >= cols { cc = cols - 1 }
                            i = i + 1
                        } else {
                            if c >= 32 {                                             // printable
                                let idx = cr * cols + cc
                                let pfg = pen / 256
                                grid = _put(grid, idx, substring(s, i, i + 1))
                                attr = _put(attr, idx, fromCharCode(pfg))
                                battr = _put(battr, idx, fromCharCode(pen - pfg * 256))
                                cc = cc + 1
                                if cc >= cols {
                                    cc = 0  cr = cr + 1
                                    if cr >= rows {
                                        grid = _scrollUp(grid, cols, total, _blank(cols))
                                        attr = _scrollUp(attr, cols, total, _fill1(cols))
                                        battr = _scrollUp(battr, cols, total, _fill1(cols))
                                        cr = rows - 1
                                    }
                                }
                            }
                            i = i + 1
                        }
                    }
                }
            }
        }
    }

    // Render: each row trimmed of trailing spaces, joined by \n, foreground
    // colour re-emitted as ANSI (reset at each row end if a colour was active).
    let out = sbNew()
    let r = 0
    while r < rows {
        let base = r * cols
        let rowstr = substring(grid, base, base + cols)
        let e = len(rowstr)
        while e > 0 && charCode(substring(rowstr, e - 1, e)) == 32 { e = e - 1 }
        let lastFg = 1
        let lastBg = 1
        let col = 0
        while col < e {
            let cellFg = charCode(substring(attr, base + col, base + col + 1))
            let cellBg = charCode(substring(battr, base + col, base + col + 1))
            if cellFg != lastFg || cellBg != lastBg {
                out = sbAppend(out, _sgrPair(cellFg, cellBg))
                lastFg = cellFg
                lastBg = cellBg
            }
            out = sbAppend(out, substring(rowstr, col, col + 1))
            col = col + 1
        }
        if lastFg != 1 || lastBg != 1 { out = sbAppend(out, fromCharCode(27) + "[0m") }
        if r < rows - 1 { out = sbAppend(out, fromCharCode(10)) }
        r = r + 1
    }
    emit sbToString(out)
}
