// term.k — kryoterm grid driver (pure Krypton terminal core, phase 4).
//
// The next layer up from ansi.k: maintains a rows×cols character grid with a
// cursor and ACTS on the common VT sequences — cursor positioning
// (CUP/CUU/CUD/CUF/CUB), erase (ED/EL), CR/LF/BS/TAB — then renders the grid
// back to text. Krypton port of brain/terk's Grid + Terminal::applyEscape,
// minus colors (SGR consumed for now; per-cell attrs land when the renderer
// needs them).
//
// The grid is a FLAT string of rows*cols chars (index = row*cols + col), spliced
// on each write. k:map looked cleaner but is broken on the macho backend (hash
// collisions drop keys, mapSize miscounts — 2026-06-06), so this uses only
// charCode/substring/len/sbAppend, all verified-working native builtins. No C,
// no FFI, no maps. All state is local to renderGrid (Krypton modules don't keep
// state across the import boundary).

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

// _put(grid, idx, ch) — return grid with the char at flat index idx replaced.
func _put(grid, idx, ch) {
    emit substring(grid, 0, idx) + ch + substring(grid, idx + 1, len(grid))
}

// renderGrid(s, cols, rows) — feed byte string s into a cols×rows grid, apply
// cursor/erase sequences, return the grid as text (rows joined by \n, trailing
// spaces trimmed per row).
func renderGrid(s, cols, rows) {
    let total = cols * rows
    let grid = _blank(total)
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
                        if fin == 74 {                   // 'J' erase display (2/3 = all)
                            if _leadInt(params, 0) >= 2 { grid = _blank(total)  cr = 0  cc = 0 }
                        }
                        if fin == 75 {                   // 'K' erase whole line
                            let st = cr * cols
                            grid = substring(grid, 0, st) + _blank(cols) + substring(grid, st + cols, total)
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
            if c == 10 { cr = cr + 1  cc = 0  if cr >= rows { cr = rows - 1 }  i = i + 1 }   // LF → newline (col reset, matches brain)
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
                                grid = _put(grid, cr * cols + cc, substring(s, i, i + 1))
                                cc = cc + 1
                                if cc >= cols { cc = 0  cr = cr + 1  if cr >= rows { cr = rows - 1 } }
                            }
                            i = i + 1
                        }
                    }
                }
            }
        }
    }

    // Render: each row trimmed of trailing spaces, joined by \n.
    let out = sbNew()
    let r = 0
    while r < rows {
        let rowstr = substring(grid, r * cols, r * cols + cols)
        let e = len(rowstr)
        while e > 0 && charCode(substring(rowstr, e - 1, e)) == 32 { e = e - 1 }
        out = sbAppend(out, substring(rowstr, 0, e))
        if r < rows - 1 { out = sbAppend(out, fromCharCode(10)) }
        r = r + 1
    }
    emit sbToString(out)
}
