// stem_wl.ks — stem's Wayland/Hyprland windowed frontend (pure Krypton).
//
// MVP: host stem's terminal engine (PTY + VT grid) inside a k:wayland window.
// Reuses: k:wayland (surface + software framebuffer + 8x16 font + keyboard),
// stem term.k (VT/grid), stem pty.k (PTY), stem config.k (stem.conf).
//
// This is the .ks orchestration layer — the perf-critical grid/VT/PTY live in
// the imported compiled .k modules; the event loop + wiring live here.
//
// Run:  kcc -r kghostty.ks    (needs a running Wayland compositor, e.g. Hyprland)

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

// ── render: stem grid -> framebuffer (monochrome MVP; colors = future) ───────
func kDrawScreen(px, W, H, font, st, cols, rows, bg, fg) {
    fbClear(px, W, H, bg)
    let text = gridRender(st, cols, rows)
    let n = toInt(lineCount(text))
    let i = 0
    while i < n && i < rows {
        let line = getLine(text, i)
        fbDrawText(px, W, H, font, 4, 2 + i * 16, line, fg)
        i = i + 1
    }
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
    // connection (and thus the window) alive after kghostty exits — orphan
    // zombie windows that ignore close. Forking before connect avoids that.
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    let childPid = ptyForkExec(slave, shell)

    // ── wayland surface (child already forked: it has no Wayland fd) ──
    let fd = wlConnect()
    if fd < 0 { print("kghostty: wayland connect failed")  exit("1") }
    let REG = 2  let COMP = 3  let SHM = 4  let WM = 5  let SEAT = 6  let KB = 7
    let SURF = 8  let XS = 9  let TOP = 10   // sequential object ids, NO gaps
    wlGetRegistry(fd, REG)
    let rb = bufNew(8192)
    let rn = wlRecvInto(fd, rb, 8192)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_compositor"), "wl_compositor", 4, COMP)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_shm"), "wl_shm", 1, SHM)
    wlBind(fd, REG, _wlFind(rb, rn, "xdg_wm_base"), "xdg_wm_base", 1, WM)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_seat"), "wl_seat", 5, SEAT)
    wlGetKeyboard(fd, SEAT, KB)
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
    let nextId = 11  let prevBuf = 0  let prevPool = 0  let prevMfd = 0
    let dirty = 1  let running = 1  let configured = 0  let ptyBytes = 0
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
                if obj == KB && op == 1 { shift = 0  ctrl = 0 }   // modifiers (simplified)
                if obj == KB && op == 3 {
                    let state = wlU32(eb, off + 20)
                    let kc = wlKeyToKc(wlU32(eb, off + 16))
                    if state == 1 {
                        if kc == 50 || kc == 62 { shift = 1 }
                        if kc == 37 || kc == 105 { ctrl = 1 }
                        let bytes = kKeyBytes(kc, shift, ctrl)
                        if bytes != "" { fdWrite(m, bytes, len(bytes)) }
                    } else {
                        if kc == 50 || kc == 62 { shift = 0 }
                        if kc == 37 || kc == 105 { ctrl = 0 }
                    }
                }
                off = off + s
            }
        }
        // 2) drain pty output -> grid
        let out = fdRead(m, 16384)
        if len(out) > 0 { st = gridFeed(st, out, cols, rows)  dirty = 1 }

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
            kDrawScreen(px, W, H, font, st, cols, rows, bg, fg)
            wlCreatePool(fd, SHM, pool, fb, sz)
            wlPoolCreateBuffer(fd, pool, buf, 0, W, H, stride, 1)
            wlSurfaceAttach(fd, SURF, buf, 0, 0)
            wlDamage(fd, SURF, 0, 0, W, H)
            wlCommit(fd, SURF)
            prevBuf = buf  prevPool = pool  prevMfd = fb
            dirty = 0
        }
        sleepUs(0, 8000)               // ~8ms poll
    }
    // clean shutdown: closing the pty master hangs up the shell (SIGHUP); drop
    // the wayland connection so the surface is destroyed (no orphan window).
    fdClose(m)
    sockClose(fd)
    emit 0
}
