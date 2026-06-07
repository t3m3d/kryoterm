// term.k — kryoterm grid driver (pure Krypton terminal core, phase 4).
//
// Maintains a rows×cols cell grid with a cursor and ACTS on the common VT
// sequences — cursor positioning (CUP/CUU/CUD/CUF/CUB), erase (ED/EL), CR/LF/
// BS/TAB, SGR fg+bg colour, scroll-on-overflow — then renders the grid back to
// text (re-emitting ANSI colour). Krypton port of brain/terk's Grid + applyEscape.
//
// Two representations of state:
//   - one-shot:    renderGrid(s, cols, rows)            -> text
//   - incremental: gridNew(cols,rows) -> state          (a packed string)
//                  gridFeed(state, bytes, cols, rows)   -> state
//                  gridRender(state, cols, rows)        -> text
// The interactive loop keeps `state` across frames and feeds only the new bytes,
// so it never re-processes the whole stream (renderGrid is O(input×gridsize)).
//
// The CHARACTER grid uses 5-byte slots per cell: [width][b0][b1][b2][b3], width
// 1-4 = how many following bytes are the cell's UTF-8 character (rest SOH-padded)
// — so a multi-byte glyph occupies one display column. `attr` (fg) and `battr`
// (bg) grids are 1 byte/cell (SGR colour code, sentinel 1 = default). The packed
// state string is grid+attr+battr+"|"+cr+","+cc+","+pen. Every byte is non-NUL
// (widths 1-4, SOH pad, colour codes >=30, UTF-8 >=0x20, header is ASCII). Uses
// only charCode/substring/len/sbAppend/fromCharCode — verified native builtins
// (k:map is broken on macho). No C, no FFI, no maps.

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

// _cf(s, k) — the k-th comma-separated non-negative integer field of s (0 if none).
func _cf(s, k) {
    let n = len(s)
    let i = 0
    let field = 0
    let v = 0
    while i < n {
        let c = charCode(substring(s, i, i + 1))
        if c == 44 { if field == k { emit v }  field = field + 1  v = 0 }
        else { if c >= 48 && c <= 57 { v = v * 10 + (c - 48) } }
        i = i + 1
    }
    if field == k { emit v }
    emit 0
}

// _fill1(size) — a string of `size` SOH bytes (the default-colour sentinel).
func _fill1(size) {
    let sb = sbNew()
    let one = fromCharCode(1)
    let i = 0
    while i < size { sb = sbAppend(sb, one)  i = i + 1 }
    emit sbToString(sb)
}

// _cellBlank() — one blank char-grid slot: width 1, a space, 3 SOH pad bytes.
func _cellBlank() {
    emit fromCharCode(1) + " " + fromCharCode(1) + fromCharCode(1) + fromCharCode(1)
}

// _blankRow(cols) — `cols` blank char-grid slots (cols*5 bytes).
func _blankRow(cols) {
    let sb = sbNew()
    let b = _cellBlank()
    let i = 0
    while i < cols { sb = sbAppend(sb, b)  i = i + 1 }
    emit sbToString(sb)
}

// _putCell(g, cellIdx, chstr) — store the (1-4 byte) UTF-8 char in slot cellIdx.
func _putCell(g, cellIdx, chstr) {
    let w = len(chstr)
    let pad = ""
    let k = w
    while k < 4 { pad = pad + fromCharCode(1)  k = k + 1 }
    let off = cellIdx * 5
    emit substring(g, 0, off) + fromCharCode(w) + chstr + pad + substring(g, off + 5, len(g))
}

// _put1(g, idx, ch) — replace the 1-byte cell at idx (attr/battr grids).
func _put1(g, idx, ch) {
    emit substring(g, 0, idx) + ch + substring(g, idx + 1, len(g))
}

// _scrollUp(g, stride, gtotal, fillRow) — drop the top row, append a fresh
// bottom row (generic over byte-stride: char grid = cols*5, attr = cols).
func _scrollUp(g, stride, gtotal, fillRow) {
    emit substring(g, stride, gtotal) + fillRow
}

// _applySgr(pen, params) — fold an SGR list (e.g. "1;31;44") into the colour pen
// (fg*256+bg, sentinel 1 each): fg 30-37/39/90-97, bg 40-47/49/100-107.
func _applySgr(pen, params) {
    let n = len(params)
    if n == 0 { emit 257 }
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

// _sgrPair(fg, bg) — ANSI to set (fg,bg); 1 = default. Reset-then-set.
func _sgrPair(fg, bg) {
    let e = fromCharCode(27)
    let s = e + "[0m"
    if fg != 1 { s = s + e + "[" + (fg + 0) + "m" }
    if bg != 1 { s = s + e + "[" + (bg + 0) + "m" }
    emit s
}

// _utf8Len(c) — byte length of a UTF-8 char from its lead byte (1 if invalid).
func _utf8Len(c) {
    if c >= 240 && c <= 247 { emit 4 }
    if c >= 224 && c <= 239 { emit 3 }
    if c >= 192 && c <= 223 { emit 2 }
    emit 1
}

// gridNew(cols, rows) — a fresh blank packed grid state.
func gridNew(cols, rows) {
    let total = cols * rows
    let grid = _blankRow(cols)
    let rr = 1
    while rr < rows { grid = grid + _blankRow(cols)  rr = rr + 1 }
    emit grid + _fill1(total) + _fill1(total) + "|0,0,257"
}

// gridFeed(state, s, cols, rows) — process byte string s against the packed
// state (cursor/erase/colour/scroll), return the new packed state.
func gridFeed(state, s, cols, rows) {
    let total = cols * rows
    let g5 = 5 * total
    let gtotal = g5
    let stride = cols * 5
    let grid = substring(state, 0, g5)
    let attr = substring(state, g5, g5 + total)
    let battr = substring(state, g5 + total, g5 + 2 * total)
    let tail = substring(state, g5 + 2 * total + 1, len(state))
    let cr = _cf(tail, 0)
    let cc = _cf(tail, 1)
    let pen = _cf(tail, 2)
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
                            if _leadInt(params, 0) >= 2 {
                                grid = _blankRow(cols)
                                let q = 1
                                while q < rows { grid = grid + _blankRow(cols)  q = q + 1 }
                                attr = _fill1(total)  battr = _fill1(total)  cr = 0  cc = 0
                            }
                        }
                        if fin == 75 {                   // 'K' erase whole line
                            let st = cr * cols
                            grid = substring(grid, 0, st * 5) + _blankRow(cols) + substring(grid, st * 5 + stride, gtotal)
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
            if c == 10 {                                                         // LF → newline
                cr = cr + 1  cc = 0
                if cr >= rows {
                    grid = _scrollUp(grid, stride, gtotal, _blankRow(cols))
                    attr = _scrollUp(attr, cols, total, _fill1(cols))
                    battr = _scrollUp(battr, cols, total, _fill1(cols))
                    cr = rows - 1
                }
                i = i + 1
            }
            else {
                if c == 13 { cc = 0  i = i + 1 }                                 // CR
                else {
                    if c == 8 { if cc > 0 { cc = cc - 1 }  i = i + 1 }           // BS
                    else {
                        if c == 9 {                                              // TAB
                            cc = ((cc / 8) + 1) * 8
                            if cc >= cols { cc = cols - 1 }
                            i = i + 1
                        } else {
                            if c >= 32 {                                         // printable (incl UTF-8)
                                let clen = _utf8Len(c)
                                if i + clen > n { clen = n - i }
                                let idx = cr * cols + cc
                                let pfg = pen / 256
                                grid = _putCell(grid, idx, substring(s, i, i + clen))
                                attr = _put1(attr, idx, fromCharCode(pfg))
                                battr = _put1(battr, idx, fromCharCode(pen - pfg * 256))
                                cc = cc + 1
                                if cc >= cols {
                                    cc = 0  cr = cr + 1
                                    if cr >= rows {
                                        grid = _scrollUp(grid, stride, gtotal, _blankRow(cols))
                                        attr = _scrollUp(attr, cols, total, _fill1(cols))
                                        battr = _scrollUp(battr, cols, total, _fill1(cols))
                                        cr = rows - 1
                                    }
                                }
                                i = i + clen
                            } else { i = i + 1 }                                 // other control byte
                        }
                    }
                }
            }
        }
    }

    emit grid + attr + battr + "|" + cr + "," + cc + "," + pen
}

// gridRender(state, cols, rows) — render the packed state to text (rows joined
// by \n, trailing blanks trimmed, fg+bg colour re-emitted as ANSI).
func gridRender(state, cols, rows) {
    let total = cols * rows
    let g5 = 5 * total
    let grid = substring(state, 0, g5)
    let attr = substring(state, g5, g5 + total)
    let battr = substring(state, g5 + total, g5 + 2 * total)

    let out = sbNew()
    let r = 0
    while r < rows {
        let base = r * cols
        let e = cols
        let trimming = 1
        while e > 0 && trimming == 1 {
            let off = (base + e - 1) * 5
            let w = charCode(substring(grid, off, off + 1))
            if w == 1 && substring(grid, off + 1, off + 2) == " " { e = e - 1 }
            else { trimming = 0 }
        }
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
            let off = (base + col) * 5
            let w = charCode(substring(grid, off, off + 1))
            out = sbAppend(out, substring(grid, off + 1, off + 1 + w))
            col = col + 1
        }
        if lastFg != 1 || lastBg != 1 { out = sbAppend(out, fromCharCode(27) + "[0m") }
        if r < rows - 1 { out = sbAppend(out, fromCharCode(10)) }
        r = r + 1
    }
    emit sbToString(out)
}

// renderGrid(s, cols, rows) — one-shot: feed s into a fresh grid, render to text.
func renderGrid(s, cols, rows) {
    emit gridRender(gridFeed(gridNew(cols, rows), s, cols, rows), cols, rows)
}
