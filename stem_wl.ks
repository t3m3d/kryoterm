// stem_wl.ks — stem's Wayland/Hyprland windowed frontend (pure Krypton).
//
// MVP: host stem's terminal engine (PTY + VT grid) inside a k:wayland window.
// Reuses: k:wayland (surface + software framebuffer + 8x16 font + keyboard),
// stem term.k (VT/grid), stem pty.k (PTY), stem config.k (stem.conf).
//
// This is the .ks orchestration layer — the perf-critical grid/VT/PTY live in
// the imported compiled .k modules; the event loop + wiring live here.
//
// Run:  kcc -r stem_wl.ks    (needs a running Wayland compositor, e.g. Hyprland)

import "k:wayland"
import "./term.k"      // gridNew / gridFeed / gridRender
import "./pty.k"       // ptyMaster / ptySlaveName / ptyForkExec / fd*
import "./config.k"    // confLoad / confGet / confGetInt

// Find a wl_registry global's `name` by interface (registry obj=2, global op=0).
// (Local helper — k:wayland exposes the wire getters but not this scan.)
func _wlFind(b, n, iface) {
    let off = 0
    while off + 8 <= n {
        let sz = wlSize(b, off)
        if sz < 8 { emit -1 }
        if wlObject(b, off) == 2 && wlOpcode(b, off) == 0 {
            if wlReadStr(b, off + 12) == iface { emit wlU32(b, off + 8) }
        }
        off = off + sz
    }
    emit -1
}

// ── minimal keysym(keycode) -> bytes for the shell ───────────────────────────
// X11 keycodes (wlKeyToKc = evdev+8). Covers printable ASCII via a layout row
// map + the essential control keys. Full keymap/layout = future.
func kKeyBytes(kc, shift, ctrl) {
    let enter = fromCharCode(13)
    let bs = fromCharCode(127)
    let tab = fromCharCode(9)
    let esc = fromCharCode(27)
    if kc == 36 { emit enter }          // Return
    if kc == 22 { emit bs }             // Backspace
    if kc == 23 { emit tab }            // Tab
    if kc == 9  { emit esc }            // Escape
    // arrows -> ANSI CSI
    if kc == 111 { emit esc + "[A" }    // Up
    if kc == 116 { emit esc + "[B" }    // Down
    if kc == 114 { emit esc + "[C" }    // Right
    if kc == 113 { emit esc + "[D" }    // Left
    // navigation / editing keys
    if kc == 110 { emit esc + "[H" }    // Home
    if kc == 115 { emit esc + "[F" }    // End
    if kc == 112 { emit esc + "[5~" }   // Page Up
    if kc == 117 { emit esc + "[6~" }   // Page Down
    if kc == 118 { emit esc + "[2~" }   // Insert
    if kc == 119 { emit esc + "[3~" }   // Delete
    // printable via keyChar layout (shared shape with cortex)
    let ch = kCharOf(kc, shift)
    if ch != "" {
        if ctrl == 1 {                  // Ctrl-A..Ctrl-Z -> 0x01..0x1A
            let cc = toInt(charCode(ch))
            if cc >= 97 && cc <= 122 { emit fromCharCode((cc - 96) + "") }
        }
        emit ch
    }
    emit ""
}

// keycode -> character for the US layout home/number rows (MVP subset).
func kCharOf(kc, shift) {
    // letters: kc 24..33 = q..p ; 38..46 = a..; 52..58 = z.. ; use a table string.
    let row1 = "qwertyuiop"    // kc 24..33
    let row2 = "asdfghjkl"     // kc 38..46
    let row3 = "zxcvbnm"       // kc 52..58
    let nums = "1234567890"    // kc 10..19
    let symN = "!@#$%^&*()"    // shifted numbers
    if kc >= 24 && kc <= 33 { emit kShiftAlpha(substring(row1, kc - 24, kc - 23), shift) }
    if kc >= 38 && kc <= 46 { emit kShiftAlpha(substring(row2, kc - 38, kc - 37), shift) }
    if kc >= 52 && kc <= 58 { emit kShiftAlpha(substring(row3, kc - 52, kc - 51), shift) }
    if kc >= 10 && kc <= 19 { if shift == 1 { emit substring(symN, kc - 10, kc - 9) }  emit substring(nums, kc - 10, kc - 9) }
    if kc == 65 { emit " " }            // Space
    if kc == 20 { if shift == 1 { emit "_" }  emit "-" }
    if kc == 21 { if shift == 1 { emit "+" }  emit "=" }
    if kc == 51 { if shift == 1 { emit "|" }  emit fromCharCode(92) }   // backslash
    if kc == 47 { if shift == 1 { emit ":" }  emit ";" }
    if kc == 48 { if shift == 1 { emit fromCharCode(34) }  emit "'" }
    if kc == 59 { if shift == 1 { emit "<" }  emit "," }
    if kc == 60 { if shift == 1 { emit ">" }  emit "." }
    if kc == 61 { if shift == 1 { emit "?" }  emit "/" }
    emit ""
}
func kShiftAlpha(c, shift) {
    if shift == 1 { emit toUpper(c) }
    emit c
}

// xterm-256 colour index (0..255) -> packed 0xRRGGBB.
func xterm256rgb(idx) {
    // base-16: One Dark palette (readable on a dark bg — the VGA defaults made
    // ANSI blue 0x000080 etc. unreadable). black raised to a dark grey so black
    // text isn't invisible.
    if idx == 0  { emit 3883080 }    if idx == 1  { emit 14707829 }  // black(grey), red
    if idx == 2  { emit 10011513 }   if idx == 3  { emit 15057019 }  // green, yellow
    if idx == 4  { emit 6402031 }    if idx == 5  { emit 13007069 }  // blue, magenta
    if idx == 6  { emit 5682882 }    if idx == 7  { emit 11252415 }  // cyan, white
    if idx == 8  { emit 6054768 }    if idx == 9  { emit 14707829 }  // br.grey, br.red
    if idx == 10 { emit 10011513 }   if idx == 11 { emit 15057019 }  // br.green, br.yellow
    if idx == 12 { emit 6402031 }    if idx == 13 { emit 13007069 }  // br.blue, br.magenta
    if idx == 14 { emit 5682882 }    if idx == 15 { emit 16777215 }  // br.cyan, br.white
    if idx >= 232 { let v = 8 + (idx - 232) * 10  emit v * 65536 + v * 256 + v }  // greyscale ramp
    let n = idx - 16                  // 6x6x6 colour cube
    let r = n / 36  let g = (n - r * 36) / 6  let b = n - r * 36 - g * 6
    let rv = 0  if r > 0 { rv = 55 + r * 40 }
    let gv = 0  if g > 0 { gv = 55 + g * 40 }
    let bv = 0  if b > 0 { bv = 55 + b * 40 }
    emit rv * 65536 + gv * 256 + bv
}
// ── mutable 256-colour palette (OSC 4 can override entries) ──────────────────
// 3 bytes (R,G,B) per index. Seeded from xterm256rgb; OSC 4 rewrites entries.
func palInit() {
    let pal = bufNew(768)
    let i = 0
    while i < 256 {
        let rgb = xterm256rgb(i)
        let r = rgb / 65536  let g = (rgb - r * 65536) / 256  let b = rgb - r * 65536 - g * 256
        bufSetByte(pal, i * 3, r)  bufSetByte(pal, i * 3 + 1, g)  bufSetByte(pal, i * 3 + 2, b)
        i = i + 1
    }
    emit pal
}
func palRGB(pal, idx) {
    let o = idx * 3
    emit toInt(bufGetByte(pal, o)) * 65536 + toInt(bufGetByte(pal, o + 1)) * 256 + toInt(bufGetByte(pal, o + 2))
}
func palSet(pal, idx, rgb) {
    if idx < 0 || idx > 255 { emit 0 }
    let r = rgb / 65536  let g = (rgb - r * 65536) / 256  let b = rgb - r * 65536 - g * 256
    bufSetByte(pal, idx * 3, r)  bufSetByte(pal, idx * 3 + 1, g)  bufSetByte(pal, idx * 3 + 2, b)
    emit 0
}

func _isHexCh(c) { if (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) { emit 1 }  emit 0 }

// parse an OSC colour spec ("#RRGGBB", "#RRRRGGGGBBBB", "rgb:rr/gg/bb") -> rgb, -1 if not.
func parseOscColor(spec) {
    let h = indexOf(spec, "#")
    if h >= 0 {
        let raw = substring(spec, h + 1, len(spec))
        let e = 0
        while e < len(raw) && _isHexCh(toInt(charCode(substring(raw, e, e + 1)))) == 1 { e = e + 1 }
        let hex = substring(raw, 0, e)
        if len(hex) >= 12 { emit hexColor(substring(hex, 0, 2) + substring(hex, 4, 6) + substring(hex, 8, 10), 0) }
        if len(hex) >= 6 { emit hexColor(substring(hex, 0, 6), 0) }
        emit 0 - 1
    }
    let r = indexOf(spec, "rgb:")
    if r >= 0 {
        let body = substring(spec, r + 4, len(spec))
        let p1 = indexOf(body, "/")
        if p1 < 0 { emit 0 - 1 }
        let cr = substring(body, 0, p1)
        let rest = substring(body, p1 + 1, len(body))
        let p2 = indexOf(rest, "/")
        if p2 < 0 { emit 0 - 1 }
        let cg = substring(rest, 0, p2)
        let cb = substring(rest, p2 + 1, len(rest))
        emit hexColor(substring(cr, 0, 2) + substring(cg, 0, 2) + substring(cb, 0, 2), 0)
    }
    emit 0 - 1
}

// scan a chunk for OSC 4 / 10 / 11 / 12; apply OSC 4 to `pal` (in place); return
// "fg,bg,cursor" rgb ints from the last 10/11/12 (-1 = unchanged).
func oscApply(s, pal) {
    let fgC = 0 - 1  let bgC = 0 - 1  let curC = 0 - 1
    let n = len(s)
    let i = 0
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 93 {
            let bstart = i + 2
            let j = bstart
            let term = 0
            while j < n && term == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj == 7 { term = 1 }
                else { if cj == 27 && j + 1 < n && toInt(charCode(substring(s, j + 1, j + 2))) == 92 { term = 1 }
                else { j = j + 1 } }
            }
            let body = substring(s, bstart, j)
            if j < n && toInt(charCode(substring(s, j, j + 1))) == 7 { i = j + 1 } else { i = j + 2 }
            let semi = indexOf(body, ";")
            if semi > 0 {
                let ps = substring(body, 0, semi)
                let rest = substring(body, semi + 1, len(body))
                if ps == "10" { let c = parseOscColor(rest)  if c >= 0 { fgC = c } }
                if ps == "11" { let c = parseOscColor(rest)  if c >= 0 { bgC = c } }
                if ps == "12" { let c = parseOscColor(rest)  if c >= 0 { curC = c } }
                if ps == "4" {
                    let r2 = rest  let go = 1
                    while go == 1 {
                        let s1 = indexOf(r2, ";")
                        if s1 < 0 { go = 0 }
                        else {
                            let idx = toInt(substring(r2, 0, s1))
                            let after = substring(r2, s1 + 1, len(r2))
                            let s2 = indexOf(after, ";")
                            let colStr = after
                            if s2 >= 0 { colStr = substring(after, 0, s2)  r2 = substring(after, s2 + 1, len(after)) }
                            else { go = 0 }
                            let col = parseOscColor(colStr)
                            if col >= 0 { palSet(pal, idx, col) }
                        }
                    }
                }
            }
        } else { i = i + 1 }
    }
    emit fgC + "," + bgC + "," + curC
}

// Scan a chunk for terminal QUERIES the program waits on, and return the bytes to
// write back to the pty. Without these, fish/zsh/ncurses stall before the prompt:
//   ESC[6n  DSR cursor position -> ESC[<row>;<col>R
//   ESC[c / ESC[0c  DA1 -> ESC[?1;2c   ;   ESC[>c  DA2 -> ESC[>1;10;0c
func termReplies(s, meta, cols, rows) {
    let e = fromCharCode(27)
    let reply = ""
    let n = len(s)
    let i = 0
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 91 {
            let j = i + 2
            let params = ""
            let fin = 0
            while j < n && fin == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj >= 64 && cj <= 126 { fin = cj }
                else { params = params + substring(s, j, j + 1) }
                j = j + 1
            }
            if fin == 110 && params == "6" {                       // DSR cursor position
                let cur = gridCursorM(meta)
                let cm = indexOf(cur, ",")
                let cr = toInt(substring(cur, 0, cm)) + 1
                let cc = toInt(substring(cur, cm + 1, len(cur))) + 1
                if cr < 1 || cr > rows { cr = 1 }
                if cc < 1 || cc > cols { cc = 1 }
                reply = reply + e + "[" + cr + ";" + cc + "R"
            }
            if fin == 99 {                                         // DA
                if params == "" || params == "0" { reply = reply + e + "[?1;2c" }       // DA1
                else { if substring(params, 0, 1) == ">" { reply = reply + e + "[>1;10;0c" } }  // DA2
            }
            i = j
        } else { i = i + 1 }
    }
    emit reply
}

// attr/battr cell byte -> rgb. <=1 = default (use `def`); >=2 = palette[byte-2].
func kColorOf(byteVal, def, pal) {
    if byteVal <= 1 { emit def }
    emit palRGB(pal, byteVal - 2)
}

// parse a hex colour string ("CCFFCC" / "#CCFFCC" / "0xCCFFCC") -> 0xRRGGBB; def if blank.
func hexColor(s, def) {
    if s == "" { emit def }
    let h = s
    if len(h) >= 2 && substring(h, 0, 2) == "0x" { h = substring(h, 2, len(h)) }
    if len(h) >= 1 && substring(h, 0, 1) == "#" { h = substring(h, 1, len(h)) }
    let v = 0
    let i = 0
    while i < len(h) {
        let c = toInt(charCode(substring(h, i, i + 1)))
        let d = 0 - 1
        if c >= 48 && c <= 57 { d = c - 48 }
        if c >= 97 && c <= 102 { d = c - 87 }
        if c >= 65 && c <= 70 { d = c - 55 }
        if d >= 0 { v = v * 16 + d }
        i = i + 1
    }
    emit v
}

// strip trailing spaces from one line (terminal selection copies rtrimmed rows).
func rtrimLine(s) {
    let n = len(s)
    while n > 0 && substring(s, n - 1, n) == " " { n = n - 1 }
    emit substring(s, 0, n)
}

// row-major slice of one line from column a (inclusive) to b (exclusive), clamped.
func kRowSlice(line, a, b) {
    let ln = len(line)
    let lo = a   if lo < 0 { lo = 0 }   if lo > ln { lo = ln }
    let hi = b   if hi < 0 { hi = 0 }   if hi > ln { hi = ln }
    if hi <= lo { emit "" }
    emit substring(line, lo, hi)
}

// extract selected text from the live grid for range (sr,sc)..(er,ec), inclusive
// of the end cell. Multi-row joins with '\n'; each row is rtrimmed.
func kSelText(gb, cols, rows, sr, sc, er, ec) {
    let r1 = sr  let c1 = sc  let r2 = er  let c2 = ec
    if r1 > r2 || (r1 == r2 && c1 > c2) {     // normalize so (r1,c1) precedes (r2,c2)
        r1 = er  c1 = ec  r2 = sr  c2 = sc
    }
    let text = gridPlainB(gb, cols, rows)
    if r1 == r2 { emit rtrimLine(kRowSlice(getLine(text, r1), c1, c2 + 1)) }
    let out = rtrimLine(kRowSlice(getLine(text, r1), c1, cols))
    let r = r1 + 1
    while r < r2 {
        out = out + fromCharCode(10) + rtrimLine(getLine(text, r))
        r = r + 1
    }
    out = out + fromCharCode(10) + rtrimLine(kRowSlice(getLine(text, r2), 0, c2 + 1))
    emit out
}

// is cell (r,c) inside the inclusive linear selection (sr,sc)..(er,ec)?
func kInSel(r, c, cols, sr, sc, er, ec) {
    let r1 = sr  let c1 = sc  let r2 = er  let c2 = ec
    if r1 > r2 || (r1 == r2 && c1 > c2) { r1 = er  c1 = ec  r2 = sr  c2 = sc }
    let pos = r * cols + c
    let lo = r1 * cols + c1
    let hi = r2 * cols + c2
    if pos >= lo && pos <= hi { emit 1 }
    emit 0
}

// UTF-8: byte count of a sequence from its lead byte, and codepoint decode.
// The grid is one CELL per column but a cell may hold a multibyte glyph, so the
// renderer must walk the row by character (not byte) to keep columns aligned.
func kUtf8Len(b) {
    if b < 128 { emit 1 }
    if b < 224 { emit 2 }
    if b < 240 { emit 3 }
    emit 4
}
func kUtf8Cp(s, i, cl) {
    let b0 = toInt(charCode(substring(s, i, i + 1)))
    if cl == 1 { emit b0 }
    if cl == 2 {
        let b1 = toInt(charCode(substring(s, i + 1, i + 2)))
        emit (b0 - 192) * 64 + (b1 - 128)
    }
    if cl == 3 {
        let b1 = toInt(charCode(substring(s, i + 1, i + 2)))
        let b2 = toInt(charCode(substring(s, i + 2, i + 3)))
        emit (b0 - 224) * 4096 + (b1 - 128) * 64 + (b2 - 128)
    }
    let c1 = toInt(charCode(substring(s, i + 1, i + 2)))
    let c2 = toInt(charCode(substring(s, i + 2, i + 3)))
    let c3 = toInt(charCode(substring(s, i + 3, i + 4)))
    emit (b0 - 240) * 262144 + (c1 - 128) * 4096 + (c2 - 128) * 64 + (c3 - 128)
}
// codepoint of the col-th character in a UTF-8 line (32 = space if past the end)
func kCharAtCol(line, col) {
    let n = len(line)
    let bi = 0
    let c = 0
    while bi < n {
        let lead = toInt(charCode(substring(line, bi, bi + 1)))
        let cl = kUtf8Len(lead)
        if bi + cl > n { cl = n - bi }
        if c == col { emit kUtf8Cp(line, bi, cl) }
        bi = bi + cl
        c = c + 1
    }
    emit 32
}

// ── render: stem grid -> framebuffer, per-cell ANSI colour. Block cursor; bell. ──
func kDrawScreen(px, W, H, font, gb, ab, bb, meta, cols, rows, bg, fg, bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC, pal) {
    let back = bg
    if bell == 1 { back = 3355494 }                 // visual-bell flash
    fbClear(px, W, H, back)
    let total = cols * rows
    let text = gridPlainB(gb, cols, rows)
    let r = 0
    while r < rows {
        let line = getLine(text, r)
        let llen = len(line)
        let bi = 0                      // byte cursor into the (possibly multibyte) row
        let c = 0
        while c < cols {
            let idx = r * cols + c
            let x = 4 + c * 8  let y = 2 + r * 16
            let cellFg = kColorOf(toInt(bufGetByte(ab, idx)), fg, pal)
            let cellBg = kColorOf(toInt(bufGetByte(bb, idx)), back, pal)
            if hasSel == 1 && kInSel(r, c, cols, selSR, selSC, selER, selEC) == 1 {
                cellBg = 3756378            // 0x395A5A selection highlight
            }
            if cellBg != back { fbFillRect(px, W, x, y, 8, 16, cellBg) }
            if bi < llen {
                let lead = toInt(charCode(substring(line, bi, bi + 1)))
                let cl = kUtf8Len(lead)
                if bi + cl > llen { cl = llen - bi }
                let chcode = kUtf8Cp(line, bi, cl)
                if chcode != 32 { fbDrawChar(px, W, H, font, x, y, chcode, cellFg) }
                bi = bi + cl
            }
            c = c + 1
        }
        r = r + 1
    }
    // block cursor (inverted cell) at gridCursor row,col
    let cur = gridCursorM(meta)
    let comma = indexOf(cur, ",")
    let cr = toInt(substring(cur, 0, comma))
    let cc = toInt(substring(cur, comma + 1, len(cur)))
    if cr >= 0 && cr < rows && cc >= 0 && cc < cols {
        let cx = 4 + cc * 8  let cy = 2 + cr * 16
        let cline = getLine(text, cr)
        let cglyph = kCharAtCol(cline, cc)              // col-th char (UTF-8 aware)
        let cstyle = curStyle                            // app DECSCUSR overrides the config default
        let appShape = gridCshapeM(meta)
        if appShape == 1 { cstyle = 1 }                 // bar
        if appShape == 2 { cstyle = 0 }                 // block
        if appShape == 3 { cstyle = 2 }                 // underline
        if cstyle == 1 {                                // bar: 2px at cell left, glyph normal
            fbFillRect(px, W, cx, cy, 2, 16, curColor)
            if cglyph != 32 { fbDrawChar(px, W, H, font, cx, cy, cglyph, fg) }
        } else {
            if cstyle == 2 {                            // underline: 2px at cell bottom, glyph normal
                fbFillRect(px, W, cx, cy + 14, 8, 2, curColor)
                if cglyph != 32 { fbDrawChar(px, W, H, font, cx, cy, cglyph, fg) }
            } else {                                    // block: fill cell, glyph inverted
                fbFillRect(px, W, cx, cy, 8, 16, curColor)
                if cglyph != 32 { fbDrawChar(px, W, H, font, cx, cy, cglyph, back) }
            }
        }
    }
}

// scrollback view: history + live grid, offset up by scrollOff lines (monochrome —
// scrolled-off rows are stored as plain text). A "▲" marks we're not at the bottom.
func kDrawScrollback(px, W, H, font, scrollback, gb, cols, rows, scrollOff, bg, fg) {
    fbClear(px, W, H, bg)
    let view = gridScrollView(scrollback, gridPlainB(gb, cols, rows), rows, scrollOff)
    let r = 0
    while r < rows {
        let line = gridStripSgr(getLine(view, r))   // history rows carry SGR; strip for the mono view
        fbDrawText(px, W, H, font, 4, 2 + r * 16, line, fg)
        r = r + 1
    }
    fbDrawText(px, W, H, font, W - 80, 2, "^" + scrollOff + " (shift+pgdn=back)", 16776960)   // scroll indicator
}

just run {
    // ── config ──
    let conf = confLoad()
    let shell = confGet(conf, "shell", "/bin/bash")
    let term = confGet(conf, "term", "xterm-256color")          // $TERM for the child
    let bg = hexColor(confGet(conf, "bg", ""), 1054753)         // 0x101821 dark
    let fg = hexColor(confGet(conf, "fg", ""), 13434828)        // 0xCCFFCC soft green
    let curColor = hexColor(confGet(conf, "cursor_color", ""), fg)
    let curStyleS = confGet(conf, "cursor_style", "block")      // block | bar | underline
    let curStyle = 0
    if curStyleS == "bar" { curStyle = 1 }
    if curStyleS == "underline" { curStyle = 2 }
    let bellMode = confGet(conf, "bell", "visual")             // visual | off

    // initial size from config grid (a tiling compositor may override on map).
    let cfgCols = confGetInt(conf, "cols", 100)
    let cfgRows = confGetInt(conf, "rows", 30)
    if cfgCols < 20 { cfgCols = 20 }   if cfgCols > 400 { cfgCols = 400 }
    if cfgRows < 5  { cfgRows = 5 }    if cfgRows > 200 { cfgRows = 200 }
    let W = cfgCols * 8 + 8  let H = cfgRows * 16 + 4
    let cols = (W - 8) / 8
    let rows = (H - 4) / 16

    // ── pty + shell FIRST, BEFORE wlConnect ──
    // The shell is forked here; if we connected to Wayland first, the forked
    // child would inherit the Wayland socket fd and keep the compositor
    // connection (and thus the window) alive after stem exits — orphan
    // zombie windows that ignore close. Forking before connect avoids that.
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    // ptyForkExec inherits stem's environment, and a Wayland session (Hyprland)
    // usually has no TERM — so fish/ncurses/clear break ("TERM not set"). There is
    // no setenv builtin, so launch the shell through a tiny wrapper that exports
    // TERM first. As a bonus `shell` may now carry args (e.g. "/usr/bin/fish -l").
    let nl = fromCharCode(10)
    let wrapPath = "/tmp/.stem-shell-" + m
    let wrap = "#!/bin/sh" + nl + "export TERM=" + term + nl + "export COLORTERM=truecolor" + nl + "exec " + shell + nl
    writeFile(wrapPath, wrap)
    exec("chmod +x " + wrapPath + " 2>/dev/null")
    let childPid = ptyForkExec(slave, wrapPath)

    // ── wayland surface (child already forked: it has no Wayland fd) ──
    let fd = wlConnect()
    if fd < 0 { print("stem: wayland connect failed")  exit("1") }
    let REG = 2  let COMP = 3  let SHM = 4  let WM = 5  let SEAT = 6  let KB = 7  let PTR = 8
    let SURF = 9  let XS = 10  let TOP = 11   // sequential object ids, NO gaps
    wlGetRegistry(fd, REG)
    let rb = bufNew(8192)
    let rn = wlRecvInto(fd, rb, 8192)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_compositor"), "wl_compositor", 4, COMP)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_shm"), "wl_shm", 1, SHM)
    wlBind(fd, REG, _wlFind(rb, rn, "xdg_wm_base"), "xdg_wm_base", 1, WM)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_seat"), "wl_seat", 5, SEAT)
    wlGetKeyboard(fd, SEAT, KB)
    wlGetPointer(fd, SEAT, PTR)
    wlCreateSurface(fd, COMP, SURF)
    wlGetXdgSurface(fd, WM, XS, SURF)
    wlGetToplevel(fd, XS, TOP)
    wlSetTitle(fd, TOP, "stem")
    wlSetAppId(fd, TOP, "stem")
    wlCommit(fd, SURF)

    let font = wlFontLoad()
    let tries = 0
    while tries < 60 { if ptySetSize(m, rows, cols) == 0 { tries = 60 } else { sleepUs(0, 10000)  tries = tries + 1 } }
    ptySetNonblock(m)
    fdSetNonblock(fd)                  // wayland fd: poll, don't block
    // persistent plane buffers (mutated in place by gridFeedB — no per-feed alloc)
    let gb = bufNew(5 * cols * rows)  let ab = bufNew(cols * rows)  let bb = bufNew(cols * rows)
    gridBlank(gb, ab, bb, cols, rows)
    let meta = gridInitMeta()
    let pal = palInit()                // live 256-colour palette (OSC 4 overrides)

    let shift = 0  let ctrl = 0
    let nextId = 12  let prevBuf = 0  let prevPool = 0  let prevMfd = 0
    let dirty = 1  let running = 1  let configured = 0
    let kicked = 0  let kickIn = 0  let kickArmed = 0   // debounced startup Ctrl-L once the shell settles
    let title = "stem"  let bell = 0
    let pending = ""        // partial escape/UTF-8 carried between reads
    let scrollback = ""     // lines that scrolled off the top (history)
    let quiet = 0           // consecutive empty reads (flush a buffered tail)
    let scrollOff = 0       // scrollback view offset (0 = live bottom)
    let sbCap = confGetInt(conf, "scrollback", 2000)
    // mouse selection (live screen only): drag left button to select, release copies
    let selecting = 0  let hasSel = 0
    let selSR = 0  let selSC = 0  let selER = 0  let selEC = 0
    let ptrR = 0   let ptrC = 0
    let eb = bufNew(8192)              // reused every loop (was leaking 8KB/iteration)
    let fbMem = 0  let fbPx = 0  let fbPool = 0  let fbSz = 0   // shared framebuffer, reused across frames
    while running == 1 {
        // 1) drain wayland events (non-blocking)
        let en = wlRecvInto(fd, eb, 8192)
        let off = 0
        while off + 8 <= en {
            let obj = wlObject(eb, off)  let op = wlOpcode(eb, off)  let s = wlSize(eb, off)
            if s < 8 { off = en }
            else {
                if obj == WM && op == 0 { wlPong(fd, WM, wlU32(eb, off + 8)) }
                if obj == XS && op == 0 {
                    wlAckConfigure(fd, XS, wlU32(eb, off + 8))
                    // Arm a DEBOUNCED Ctrl-L: it fires ~240ms after the shell's
                    // startup output stops (each chunk resets kickIn below), so a
                    // slow shell reprints its prompt once into the final grid.
                    if configured == 0 { kickArmed = 1  kickIn = 30 }
                    configured = 1  dirty = 1
                }
                if obj == TOP && op == 0 {
                    let cw = wlU32(eb, off + 8)  let chh = wlU32(eb, off + 12)
                    if cw > 0 && chh > 0 && (cw != W || chh != H) {
                        W = cw  H = chh
                        cols = (W - 8) / 8  rows = (H - 4) / 16
                        ptySetSize(m, rows, cols)
                        gb = bufNew(5 * cols * rows)  ab = bufNew(cols * rows)  bb = bufNew(cols * rows)
                        gridBlank(gb, ab, bb, cols, rows)  meta = gridInitMeta()
                        hasSel = 0  selecting = 0
                        // a running shell redraws on SIGWINCH (ptySetSize above); only
                        // force Ctrl-L for resizes after the startup kick, else it
                        // races the shell's startup and stacks/blanks the prompt.
                        if kicked == 1 { fdWrite(m, fromCharCode(12), 1) }
                        dirty = 1
                    }
                }
                if obj == TOP && op == 1 { running = 0 }    // xdg_toplevel.close -> exit cleanly (keybind close works)
                if obj == 1 && op == 0 { running = 0 }      // wl_display.error
                if obj == KB && op == 4 {                    // wl_keyboard.modifiers (authoritative)
                    let mods = wlU32(eb, off + 12)           // mods_depressed bitmask
                    shift = 0  if bitAnd(mods, 1) != 0 { shift = 1 }   // bit0 = shift
                    ctrl = 0   if bitAnd(mods, 4) != 0 { ctrl = 1 }    // bit2 = ctrl
                }
                if obj == KB && op == 3 {                    // wl_keyboard.key
                    let state = wlU32(eb, off + 20)
                    let kc = wlKeyToKc(wlU32(eb, off + 16))
                    if state == 1 {
                        if hasSel == 1 { hasSel = 0  dirty = 1 }     // typing clears the selection
                        // Shift+PageUp/Down scrolls the scrollback (not sent to shell).
                        if shift == 1 && kc == 112 {
                            scrollOff = scrollOff + rows - 2
                            let maxOff = toInt(lineCount(scrollback))
                            if scrollOff > maxOff { scrollOff = maxOff }
                            dirty = 1
                        }
                        else { if shift == 1 && kc == 117 {
                            scrollOff = scrollOff - (rows - 2)
                            if scrollOff < 0 { scrollOff = 0 }
                            dirty = 1
                        } else {
                            // paste: Ctrl-Shift-V (kc 55) or Shift-Insert (kc 118)
                            let isPaste = 0
                            if ctrl == 1 && shift == 1 && kc == 55 { isPaste = 1 }
                            if shift == 1 && kc == 118 { isPaste = 1 }
                            if isPaste == 1 {
                                let clip = exec("wl-paste -n 2>/dev/null")
                                if len(clip) > 0 { fdWrite(m, clip, len(clip)) }
                                if scrollOff != 0 { scrollOff = 0  dirty = 1 }
                            } else {
                                if scrollOff != 0 { scrollOff = 0  dirty = 1 }   // any other key jumps back to live
                                let bytes = kKeyBytes(kc, shift, ctrl)
                                if bytes != "" { fdWrite(m, bytes, len(bytes)) }
                            }
                        } }
                    }
                }
                if obj == PTR && op == 2 {                   // wl_pointer.motion -> track cell
                    let px = toInt(wlU32(eb, off + 12)) / 256   // wl_fixed -> px
                    let py = toInt(wlU32(eb, off + 16)) / 256
                    ptrC = (px - 4) / 8   if ptrC < 0 { ptrC = 0 }  if ptrC >= cols { ptrC = cols - 1 }
                    ptrR = (py - 2) / 16  if ptrR < 0 { ptrR = 0 }  if ptrR >= rows { ptrR = rows - 1 }
                    if selecting == 1 { selER = ptrR  selEC = ptrC  hasSel = 1  dirty = 1 }
                }
                if obj == PTR && op == 3 {                   // wl_pointer.button
                    let btn = wlU32(eb, off + 16)            // BTN_LEFT = 272
                    let bstate = wlU32(eb, off + 20)         // 1 = pressed
                    if btn == 272 {
                        if bstate == 1 {                     // press: anchor selection at cursor cell
                            selecting = 1  hasSel = 0
                            selSR = ptrR  selSC = ptrC  selER = ptrR  selEC = ptrC
                            dirty = 1
                        } else {                             // release: copy selection to clipboard
                            selecting = 0
                            if hasSel == 1 && scrollOff == 0 {
                                let seltext = kSelText(gb, cols, rows, selSR, selSC, selER, selEC)
                                if len(seltext) > 0 {
                                    writeFile("/tmp/.stem_sel", seltext)
                                    exec("wl-copy < /tmp/.stem_sel 2>/dev/null")
                                    exec("wl-copy --primary < /tmp/.stem_sel 2>/dev/null")   // X-style PRIMARY
                                }
                            }
                        }
                    }
                    // middle-click pastes the PRIMARY selection (the Linux idiom)
                    if btn == 274 && bstate == 1 {
                        let clip = exec("wl-paste --primary -n 2>/dev/null")
                        if len(clip) > 0 { fdWrite(m, clip, len(clip)) }
                        if scrollOff != 0 { scrollOff = 0  dirty = 1 }
                    }
                }
                if obj == PTR && op == 4 {                   // wl_pointer.axis (scroll wheel)
                    let ax = wlU32(eb, off + 12)             // 0 = vertical
                    if ax == 0 {
                        let msb = toInt(bufGetByte(eb, off + 19))   // sign byte of the wl_fixed value (LE MSB)
                        if msb >= 128 {                      // negative -> wheel up -> into history
                            scrollOff = scrollOff + 3
                            let maxOff = toInt(lineCount(scrollback))
                            if scrollOff > maxOff { scrollOff = maxOff }
                            dirty = 1
                        } else {                             // positive -> wheel down -> toward live
                            scrollOff = scrollOff - 3
                            if scrollOff < 0 { scrollOff = 0 }
                            dirty = 1
                        }
                    }
                }
                off = off + s
            }
        }
        // debounced startup kick: fire once the countdown elapses (reset by each
        // startup output chunk below) so the shell reprints its prompt exactly once.
        if kickArmed == 1 && kickIn > 0 {
            kickIn = kickIn - 1
            if kickIn == 0 { fdWrite(m, fromCharCode(12), 1)  kicked = 1  kickArmed = 0  dirty = 1 }
        }
        // 2) drain pty output -> grid. Carry partial escape/UTF-8 across reads
        // (gridSafeLen) or colour/box-drawing output split mid-sequence corrupts.
        let out = fdRead(m, 16384)
        if len(out) > 0 {
            if kickArmed == 1 { kickIn = 30 }   // shell still emitting startup -> hold the kick
            let chunk = pending + out
            let nt = oscTitle(chunk, title)
            if nt != title && nt != "" { title = nt  wlSetTitle(fd, TOP, title)  wlCommit(fd, SURF) }
            let cut = gridSafeLen(chunk)
            if cut > 0 {
                let fed = substring(chunk, 0, cut)
                // OSC 4/10/11/12 theming: update palette + default fg/bg/cursor.
                let oc = oscApply(fed, pal)
                let oci = indexOf(oc, ",")
                let ocFg = toInt(substring(oc, 0, oci))
                let ocR = substring(oc, oci + 1, len(oc))
                let ocj = indexOf(ocR, ",")
                let ocBg = toInt(substring(ocR, 0, ocj))
                let ocCur = toInt(substring(ocR, ocj + 1, len(ocR)))
                if ocFg >= 0 { fg = ocFg }
                if ocBg >= 0 { bg = ocBg }
                if ocCur >= 0 { curColor = ocCur }
                meta = gridFeedB(gb, ab, bb, meta, fed, cols, rows)
                // answer DSR/DA queries (post-feed cursor) so the shell doesn't stall
                let rep = termReplies(fed, meta, cols, rows)
                if len(rep) > 0 { fdWrite(m, rep, len(rep)) }
                if gridBellM(meta) == 1 { if bellMode == "visual" { bell = 1 } }   // 'off' = ignore
                let sc = gridScrolledM(meta)
                if len(sc) > 0 {
                    scrollback = scrollback + sc
                    let cap = sbCap * 200          // ~bytes budget for sbCap lines
                    if len(scrollback) > cap { scrollback = substring(scrollback, len(scrollback) - cap, len(scrollback)) }
                }
                dirty = 1
            }
            pending = substring(chunk, cut, len(chunk))
            quiet = 0
        } else {
            quiet = quiet + 1
            if quiet >= 2 && len(pending) > 0 { meta = gridFeedB(gb, ab, bb, meta, pending, cols, rows)  pending = ""  dirty = 1 }
        }

        // 3) shell exited?
        if waitChild(childPid) != 0 { running = 0 }

        // 4) present. Reuse ONE shared memfd/mmap/pool across frames (mmapShared
        // has no munmap, so a per-frame mapping leaked ~MBs/frame -> OOM crash).
        // Reallocate only when the window grows beyond the current allocation.
        if dirty == 1 && configured == 1 && running == 1 {
            let stride = W * 4
            let sz = stride * H
            if sz > fbSz {
                if fbPool != 0 {
                    if prevBuf != 0 { wlBufferDestroy(fd, prevBuf)  prevBuf = 0 }
                    wlPoolDestroy(fd, fbPool)  sockClose(fbMem)   // old mapping leaks (rare: only on grow)
                }
                fbMem = memfdCreate(sz)
                fbPx = mmapShared(fbMem, sz)
                fbPool = nextId  nextId = nextId + 1
                wlCreatePool(fd, SHM, fbPool, fbMem, sz)
                fbSz = sz
            }
            let px = fbPx
            if scrollOff > 0 { kDrawScrollback(px, W, H, font, scrollback, gb, cols, rows, scrollOff, bg, fg) }
            else { kDrawScreen(px, W, H, font, gb, ab, bb, meta, cols, rows, bg, fg, bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC, pal) }
            let didFlash = bell  bell = 0
            let buf = nextId  nextId = nextId + 1
            wlPoolCreateBuffer(fd, fbPool, buf, 0, W, H, stride, 1)
            wlSurfaceAttach(fd, SURF, buf, 0, 0)
            wlDamage(fd, SURF, 0, 0, W, H)
            wlCommit(fd, SURF)
            if prevBuf != 0 { wlBufferDestroy(fd, prevBuf) }   // free previous frame's lightweight wl_buffer
            prevBuf = buf
            dirty = 0
            if didFlash == 1 { dirty = 1 }   // bell flashed this frame -> redraw normal next frame
        }
        sleepUs(0, 8000)               // ~8ms poll
    }
    // clean shutdown: closing the pty master hangs up the shell (SIGHUP); drop
    // the wayland connection so the surface is destroyed (no orphan window).
    fdClose(m)
    sockClose(fd)
    emit 0
}
