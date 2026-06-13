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
    if idx == 0  { emit 0 }          if idx == 1  { emit 8388608 }   // black, maroon
    if idx == 2  { emit 32768 }      if idx == 3  { emit 8421376 }   // green, olive
    if idx == 4  { emit 128 }        if idx == 5  { emit 8388736 }   // navy, purple
    if idx == 6  { emit 32896 }      if idx == 7  { emit 12632256 }  // teal, silver
    if idx == 8  { emit 8421504 }    if idx == 9  { emit 16711680 }  // grey, red
    if idx == 10 { emit 65280 }      if idx == 11 { emit 16776960 }  // lime, yellow
    if idx == 12 { emit 255 }        if idx == 13 { emit 16711935 }  // blue, fuchsia
    if idx == 14 { emit 65535 }      if idx == 15 { emit 16777215 }  // aqua, white
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

// ── render: stem grid -> framebuffer, per-cell ANSI colour. Block cursor; bell. ──
func kDrawScreen(px, W, H, font, st, cols, rows, bg, fg, bell) {
    let back = bg
    if bell == 1 { back = 3355494 }                 // visual-bell flash
    fbClear(px, W, H, back)
    let total = cols * rows
    let attr  = substring(st, 5 * total, 6 * total) // per-cell fg index byte
    let battr = substring(st, 6 * total, 7 * total) // per-cell bg index byte
    let text = gridRender(st, cols, rows)
    let r = 0
    while r < rows {
        let line = getLine(text, r)
        let llen = len(line)
        let c = 0
        while c < cols {
            let idx = r * cols + c
            let x = 4 + c * 8  let y = 2 + r * 16
            let cellBg = kColorOf(toInt(charCode(substring(battr, idx, idx + 1))), back)
            if cellBg != back { fbFillRect(px, W, x, y, 8, 16, cellBg) }
            if c < llen {
                let chcode = toInt(charCode(substring(line, c, c + 1)))
                if chcode != 32 { fbDrawChar(px, W, H, font, x, y, chcode, kColorOf(toInt(charCode(substring(attr, idx, idx + 1))), fg)) }
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
        fbFillRect(px, W, cx, cy, 8, 16, fg)
        let cline = getLine(text, cr)
        if cc < len(cline) { fbDrawChar(px, W, H, font, cx, cy, toInt(charCode(substring(cline, cc, cc + 1))), back) }
    }
}

// scrollback view: history + live grid, offset up by scrollOff lines (monochrome —
// scrolled-off rows are stored as plain text). A "▲" marks we're not at the bottom.
func kDrawScrollback(px, W, H, font, scrollback, st, cols, rows, scrollOff, bg, fg) {
    fbClear(px, W, H, bg)
    let view = gridScrollView(scrollback, gridRender(st, cols, rows), rows, scrollOff)
    let r = 0
    while r < rows {
        let line = getLine(view, r)
        fbDrawText(px, W, H, font, 4, 2 + r * 16, line, fg)
        r = r + 1
    }
    fbDrawText(px, W, H, font, W - 80, 2, "^" + scrollOff + " (shift+pgdn=back)", 16776960)   // scroll indicator
}

just run {
    // ── config ──
    let conf = confLoad()
    let shell = confGet(conf, "shell", "/bin/bash")
    let bg = 1054753           // 0x101821 dark (0xRRGGBB; fb writes alpha=0)
    let fg = 13434828          // 0xCCFFCC soft green (the krypton look)

    let W = 800  let H = 480
    let cols = (W - 8) / 8
    let rows = (H - 4) / 16

    // ── pty + shell FIRST, BEFORE wlConnect ──
    // The shell is forked here; if we connected to Wayland first, the forked
    // child would inherit the Wayland socket fd and keep the compositor
    // connection (and thus the window) alive after stem exits — orphan
    // zombie windows that ignore close. Forking before connect avoids that.
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    let childPid = ptyForkExec(slave, shell)

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
    let title = "stem"  let bell = 0
    let pending = ""        // partial escape/UTF-8 carried between reads
    let scrollback = ""     // lines that scrolled off the top (history)
    let quiet = 0           // consecutive empty reads (flush a buffered tail)
    let scrollOff = 0       // scrollback view offset (0 = live bottom)
    let sbCap = confGetInt(conf, "scrollback", 2000)
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
                    if configured == 0 { fdWrite(m, fromCharCode(12), 1) }   // first map: Ctrl-L -> shell reprints its prompt
                    configured = 1  dirty = 1
                }
                if obj == TOP && op == 0 {
                    let cw = wlU32(eb, off + 8)  let chh = wlU32(eb, off + 12)
                    if cw > 0 && chh > 0 && (cw != W || chh != H) {
                        W = cw  H = chh
                        cols = (W - 8) / 8  rows = (H - 4) / 16
                        ptySetSize(m, rows, cols)
                        st = gridNew(cols, rows)
                        fdWrite(m, fromCharCode(12), 1)   // resize wiped the grid -> Ctrl-L so the shell redraws into it
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
                if gridBell(st, cols, rows) == 1 { bell = 1 }
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
            else { kDrawScreen(px, W, H, font, st, cols, rows, bg, fg, bell) }
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
