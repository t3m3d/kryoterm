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
// attr/battr cell byte -> rgb. <=1 = default (use `def`); >=2 = xterm256[byte-2].
func kColorOf(byteVal, def) {
    if byteVal <= 1 { emit def }
    emit xterm256rgb(byteVal - 2)
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
func kSelText(st, cols, rows, sr, sc, er, ec) {
    let r1 = sr  let c1 = sc  let r2 = er  let c2 = ec
    if r1 > r2 || (r1 == r2 && c1 > c2) {     // normalize so (r1,c1) precedes (r2,c2)
        r1 = er  c1 = ec  r2 = sr  c2 = sc
    }
    let text = gridPlain(st, cols, rows)
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
func kDrawScreen(px, W, H, font, st, cols, rows, bg, fg, bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC) {
    let back = bg
    if bell == 1 { back = 3355494 }                 // visual-bell flash
    fbClear(px, W, H, back)
    let total = cols * rows
    let attr  = substring(st, 5 * total, 6 * total) // per-cell fg index byte
    let battr = substring(st, 6 * total, 7 * total) // per-cell bg index byte
    let text = gridPlain(st, cols, rows)
    let r = 0
    while r < rows {
        let line = getLine(text, r)
        let llen = len(line)
        let bi = 0                      // byte cursor into the (possibly multibyte) row
        let c = 0
        while c < cols {
            let idx = r * cols + c
            let x = 4 + c * 8  let y = 2 + r * 16
            let cellFg = kColorOf(toInt(charCode(substring(attr, idx, idx + 1))), fg)
            let cellBg = kColorOf(toInt(charCode(substring(battr, idx, idx + 1))), back)
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
    let cur = gridCursor(st, cols, rows)
    let comma = indexOf(cur, ",")
    let cr = toInt(substring(cur, 0, comma))
    let cc = toInt(substring(cur, comma + 1, len(cur)))
    if cr >= 0 && cr < rows && cc >= 0 && cc < cols {
        let cx = 4 + cc * 8  let cy = 2 + cr * 16
        let cline = getLine(text, cr)
        let cglyph = kCharAtCol(cline, cc)              // col-th char (UTF-8 aware)
        let cstyle = curStyle                            // app DECSCUSR overrides the config default
        let appShape = gridCshape(st, cols, rows)
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
func kDrawScrollback(px, W, H, font, scrollback, st, cols, rows, scrollOff, bg, fg) {
    fbClear(px, W, H, bg)
    let view = gridScrollView(scrollback, gridPlain(st, cols, rows), rows, scrollOff)
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
    let st = gridNew(cols, rows)

    let shift = 0  let ctrl = 0
    let nextId = 12  let prevBuf = 0  let prevPool = 0  let prevMfd = 0
    let dirty = 1  let running = 1  let configured = 0
    let kicked = 0  let kickIn = 0     // one-shot startup Ctrl-L once the shell is ready
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
    while running == 1 {
        // 1) drain wayland events (non-blocking)
        let eb = bufNew(8192)
        let en = wlRecvInto(fd, eb, 8192)
        let off = 0
        while off + 8 <= en {
            let obj = wlObject(eb, off)  let op = wlOpcode(eb, off)  let s = wlSize(eb, off)
            if s < 8 { off = en }
            else {
                if obj == WM && op == 0 { wlPong(fd, WM, wlU32(eb, off + 8)) }
                if obj == XS && op == 0 {
                    wlAckConfigure(fd, XS, wlU32(eb, off + 8))
                    // Arm a single delayed Ctrl-L (~200ms) so the shell — which may
                    // still be starting through the wrapper — reprints its prompt
                    // once into the final-sized grid. One kick = no stacked prompts.
                    if configured == 0 { kickIn = 25 }
                    configured = 1  dirty = 1
                }
                if obj == TOP && op == 0 {
                    let cw = wlU32(eb, off + 8)  let chh = wlU32(eb, off + 12)
                    if cw > 0 && chh > 0 && (cw != W || chh != H) {
                        W = cw  H = chh
                        cols = (W - 8) / 8  rows = (H - 4) / 16
                        ptySetSize(m, rows, cols)
                        st = gridNew(cols, rows)
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
                                let seltext = kSelText(st, cols, rows, selSR, selSC, selER, selEC)
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
        // one-shot startup kick: once the countdown elapses, nudge the shell to
        // reprint its prompt into the configured grid (it may have started late).
        if kickIn > 0 {
            kickIn = kickIn - 1
            if kickIn == 0 { fdWrite(m, fromCharCode(12), 1)  kicked = 1  dirty = 1 }
        }
        // 2) drain pty output -> grid. Carry partial escape/UTF-8 across reads
        // (gridSafeLen) or colour/box-drawing output split mid-sequence corrupts.
        let out = fdRead(m, 16384)
        if len(out) > 0 {
            let chunk = pending + out
            let nt = oscTitle(chunk, title)
            if nt != title && nt != "" { title = nt  wlSetTitle(fd, TOP, title)  wlCommit(fd, SURF) }
            let cut = gridSafeLen(chunk)
            if cut > 0 {
                st = gridFeed(st, substring(chunk, 0, cut), cols, rows)
                if gridBell(st, cols, rows) == 1 { if bellMode == "visual" { bell = 1 } }   // 'off' = ignore
                let sc = gridScrolled(st, cols, rows)
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
            if quiet >= 2 && len(pending) > 0 { st = gridFeed(st, pending, cols, rows)  pending = ""  dirty = 1 }
        }

        // 3) shell exited?
        if waitChild(childPid) != 0 { running = 0 }

        // 4) present
        if dirty == 1 && configured == 1 && running == 1 {
            if prevBuf != 0 { wlBufferDestroy(fd, prevBuf)  wlPoolDestroy(fd, prevPool)  sockClose(prevMfd) }
            let pool = nextId  let buf = nextId + 1  nextId = nextId + 2
            let stride = W * 4
            let sz = stride * H
            let fb = memfdCreate(sz)
            let px = mmapShared(fb, sz)
            if scrollOff > 0 { kDrawScrollback(px, W, H, font, scrollback, st, cols, rows, scrollOff, bg, fg) }
            else { kDrawScreen(px, W, H, font, st, cols, rows, bg, fg, bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC) }
            let didFlash = bell  bell = 0
            wlCreatePool(fd, SHM, pool, fb, sz)
            wlPoolCreateBuffer(fd, pool, buf, 0, W, H, stride, 1)
            wlSurfaceAttach(fd, SURF, buf, 0, 0)
            wlDamage(fd, SURF, 0, 0, W, H)
            wlCommit(fd, SURF)
            prevBuf = buf  prevPool = pool  prevMfd = fb
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
