// run.k — kryoterm core (phase 3: real PTY).
//
// The PTY engine landed 2026-06-07: native pty/fd syscall builtins in the
// Krypton macho backend (ptyMaster/ptySlaveName/ptyForkExec, fdRead/fdWrite/
// fdClose, fdSetNonblock, sleepUs). kryoterm now spawns a real shell on a
// pseudo-terminal, runs commands, and renders the live output through the grid
// driver — all in pure Krypton, no C. The only thing left for a windowed
// terminal is the GUI surface (objc FFI, separate track); the headless engine
// is complete.

module kryoterm

import "./pty.k"     // PTY engine wrapper (ptyOpen/Read/Write/Drain/Close)
import "./term.k"    // grid driver (renderGrid — ANSI/cursor/erase -> text)

// Open a real pty and spawn `shellPath` on it. Returns the master fd.
func kryoterm_spawn(shellPath) {
    emit ptyOpen(shellPath)
}

// Run `cmd` in a fresh shell on a pty; return the raw terminal byte stream.
// Non-blocking + 5ms-paced reads (ptyDrain) so slow output lands without
// hanging or busy-spinning.
func kryoterm_run(shellPath, cmd) {
    let nl = fromCharCode(10)
    let m = ptyOpen(shellPath)
    ptySetNonblock(m)
    ptyDrain(m, 120)                 // let the shell boot (~600ms)
    ptyWrite(m, cmd + nl + "exit" + nl)
    let raw = ptyDrain(m, 300)       // collect output (~1.5s)
    ptyClose(m)
    emit raw
}

// Render raw terminal output through the grid (cols x rows).
func kryoterm_render(raw, cols, rows) {
    print(renderGrid(raw, cols, rows))
    emit 0
}

// Phase-3 loop: run `cmd` in a shell on a pty, render the session in the grid.
// (run.ks passes a parsed argv command here.)
func kryoterm_loop(cmd) {
    let raw = kryoterm_run("/bin/zsh", cmd)
    kryoterm_render(raw, 80, 24)
    emit 0
}

// Phase-4 INTERACTIVE bridge (drives the GUI shim). Spawns a shell on a pty and
// runs a poll loop: keystrokes arrive on stdin (from the window), get forwarded
// to the shell; the shell's output is fed into the incremental grid and the
// whole frame is written to stdout (prefixed with a form-feed, the shim's
// "clear and redraw" marker). Runs until the process is killed (window close) —
// macho has no waitpid builtin to detect shell exit. cols×rows fixed at 80×24.
func kryoterm_interactive(shellPath, cols, rows) {
    // Spawn the user's real shell so it sources ~/.zshrc — their prompt, history,
    // aliases. (Earlier we used `zsh -f` for a clean prompt, but the user wants
    // their config.) term.k handles enough VT (incl ESC7/8 cursor save/restore)
    // for a powerlevel10k prompt to render.
    // Open the pty + spawn the shell directly (not ptyOpen) so we keep the child
    // pid — procAlive(pid) lets us notice when the shell exits and shut down.
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    let childPid = ptyForkExec(slave, shellPath)
    // Tell the pty its real size (TIOCSWINSZ) so zsh/programs wrap at the grid
    // width. The master ioctl ENOTTYs until the forked child has opened the
    // slave, so retry briefly until it succeeds (returns 0). zsh then gets
    // SIGWINCH and updates $COLUMNS/$LINES.
    let tries = 0
    let szdone = 0
    while tries < 60 && szdone == 0 {
        if ptySetSize(m, rows, cols) == 0 { szdone = 1 }
        else { sleepUs(0, 10000)  tries = tries + 1 }
    }
    ptySetNonblock(m)
    fdSetNonblock(0)                       // stdin (keys from the window)
    let st = gridNew(cols, rows)
    let ff = fromCharCode(12)              // frame TERMINATOR (suffix): the shim
                                           // renders bytes preceding each \f.
    // Frame coalescing: feed all available output into the grid, but only emit a
    // frame once output has SETTLED (no new bytes for a couple of poll cycles).
    // A burst (e.g. a prompt redraw) becomes ONE redraw instead of many = no
    // flicker. `dirty` = grid changed since last frame; `quiet` = idle cycles.
    // NOTE: a loop-invariant `while go == 1` MISCOMPILES on macho — use a large
    // bounded counter (2e9 * 8ms ≈ months ≈ unbounded for a session).
    let dirty = 0
    let quiet = 0
    let pending = ""                      // partial escape/UTF-8 carried between reads
    let title = ""                        // window title (OSC 0/2 from the shell)
    let scrollback = ""                   // history lines that scrolled off the top
    let scrollOff = 0                     // view offset (lines up from the bottom; 0=live)
    let sbCap = 2000                      // scrollback line cap (shim sets via "L,n")
    let findQuery = ""                    // active find-in-scrollback query
    let findIdx = 0                       // which match (0 = most recent), wraps
    let findResult = "-1,-1,-1,0,0"           // matchRow,matchCol,matchLen for the shim to highlight
    let bellOn = 0                            // one-shot bell for the next frame
    let aliveCtr = 0                          // throttle the shell-alive probe
    let i = 0
    while i < 2000000000 {
        let keys = fdRead(0, 4096)
        if len(keys) > 0 {
            // Control markers from the shim: RS(0x1e) "<cmd>,<args>" RS(0x1e).
            //   R,cols,rows = resize   U,n = scroll up n   D,n = scroll down n
            // Stripped from the keystroke stream; everything else goes to the shell.
            let rs = fromCharCode(30)
            let mi = indexOf(keys, rs)
            while mi >= 0 {                       // strip ALL markers in this read
                let rest = substring(keys, mi + 1, len(keys))
                let mj = indexOf(rest, rs)
                if mj < 0 { mi = 0 - 1 }          // incomplete marker -> stop
                else {
                    let payload = substring(rest, 0, mj)
                    let c0 = indexOf(payload, ",")
                    if c0 > 0 {
                        let cmd = substring(payload, 0, c0)
                        let args = substring(payload, c0 + 1, len(payload))
                        if cmd == "R" {
                            let c1 = indexOf(args, ",")
                            if c1 > 0 {
                                let nc = toInt(substring(args, 0, c1))
                                let nr = toInt(substring(args, c1 + 1, len(args)))
                                if nc >= 4 && nr >= 2 && (nc != cols || nr != rows) {
                                    cols = nc  rows = nr
                                    st = gridNew(cols, rows)
                                    ptySetSize(m, rows, cols)
                                    scrollOff = 0          // keep scrollback (history survives resize)
                                }
                            }
                        }
                        if cmd == "U" {
                            scrollOff = scrollOff + toInt(args)
                            let mx = lineCount(scrollback)
                            if scrollOff > mx { scrollOff = mx }
                            dirty = 1  quiet = 2
                        }
                        if cmd == "D" {
                            scrollOff = scrollOff - toInt(args)
                            if scrollOff < 0 { scrollOff = 0 }
                            dirty = 1  quiet = 2
                        }
                        if cmd == "C" {                  // clear screen + scrollback
                            scrollback = ""  scrollOff = 0
                            st = gridNew(cols, rows)
                            fdWrite(m, fromCharCode(12), 1)   // Ctrl-L -> shell redraws prompt
                            dirty = 1  quiet = 2
                        }
                        if cmd == "F" { findQuery = args  findIdx = 0  dirty = 1  quiet = 2 }   // new search
                        if cmd == "N" { findIdx = findIdx + 1  dirty = 1  quiet = 2 }            // next match
                        if cmd == "P" { findIdx = findIdx - 1  dirty = 1  quiet = 2 }            // prev match
                        if cmd == "X" { findQuery = ""  findResult = "-1,-1,-1,0,0"  scrollOff = 0  dirty = 1  quiet = 2 }
                        if cmd == "L" { let nl2 = toInt(args)  if nl2 >= 100 { sbCap = nl2 } }   // scrollback cap
                        if cmd == "F" || cmd == "N" || cmd == "P" {
                            let res = gridFind(scrollback, gridRender(st, cols, rows), rows, findQuery, findIdx)
                            let c1 = indexOf(res, ",")
                            let so = toInt(substring(res, 0, c1))
                            if so < 0 { so = 0 }
                            scrollOff = so
                            findResult = substring(res, c1 + 1, len(res))
                        }
                    }
                    keys = substring(keys, 0, mi) + substring(rest, mj + 1, len(rest))
                    mi = indexOf(keys, rs)       // find the next marker
                }
            }
            if len(keys) > 0 {
                scrollOff = 0                 // a real keystroke jumps to the bottom
                fdWrite(m, keys, len(keys))
            }
        }
        let out = fdRead(m, 65536)
        if len(out) > 0 {
            // A pty read can split an escape or UTF-8 char; feed only up to the
            // last COMPLETE unit and carry the remainder to the next read, or the
            // grid corrupts (e.g. kryofetch's colour/box-drawing output).
            let chunk = pending + out
            title = oscTitle(chunk, title)
            let cut = gridSafeLen(chunk)
            if cut > 0 {
                st = gridFeed(st, substring(chunk, 0, cut), cols, rows)
                if gridBell(st, cols, rows) == 1 { bellOn = 1 }
                let sc = gridScrolled(st, cols, rows)          // rows that scrolled off
                if len(sc) > 0 {
                    scrollback = scrollback + sc
                    if scrollOff > 0 { scrollOff = scrollOff + lineCount(sc) }  // keep view put
                    let lc = lineCount(scrollback)
                    if lc > sbCap + 500 {                       // trim history back to sbCap
                        let drop = lc - sbCap
                        let p = 0
                        let seen = 0
                        while seen < drop && p < len(scrollback) {
                            if charCode(substring(scrollback, p, p + 1)) == 10 { seen = seen + 1 }
                            p = p + 1
                        }
                        scrollback = substring(scrollback, p, len(scrollback))
                        if scrollOff > sbCap { scrollOff = sbCap }
                    }
                }
            }
            pending = substring(chunk, cut, len(chunk))
            dirty = 1
            quiet = 0
        } else {
            quiet = quiet + 1
            if len(pending) > 0 {           // output stopped with a buffered tail —
                st = gridFeed(st, pending, cols, rows)   // no more reads will complete
                pending = ""                             // it, so render it as-is
                dirty = 1
            }
        }
        if dirty == 1 && quiet >= 2 {       // output settled -> one coalesced frame
            // frame = SOH cursor("row,col") SOH grid-text \f. The shim strips the
            // SOH-delimited cursor header and draws a cursor there.
            let soh = fromCharCode(1)
            let cur = gridCursor(st, cols, rows)
            let body = gridRender(st, cols, rows)
            let smax = lineCount(scrollback)
            if scrollOff > 0 {                 // viewing history: window the buffer, hide cursor
                cur = "9999,0"
                body = gridScrollView(scrollback, body, rows, scrollOff)
            }
            // header: row,col,scrollOff,scrollMax,matchRow,matchCol,matchLen,matchNum,matchTotal,bell,title
            // header: row,col,scrollOff,scrollMax,mr,mc,ml,num,total,bell,mlevel,msgr,title
            let frame = soh + cur + "," + scrollOff + "," + smax + "," + findResult + "," + bellOn + "," + gridMouse(st, cols, rows) + "," + title + soh + body + ff
            // write() to a pty can be PARTIAL (small kernel buffer); loop or the
            // frame (and its terminating \f) gets truncated and the shim never
            // sees a complete frame.
            let flen = len(frame)
            let off = 0
            while off < flen {
                let w = fdWrite(1, substring(frame, off, flen), flen - off)
                if w <= 0 { off = flen }    // error -> bail (don't spin forever)
                else { off = off + w }
            }
            dirty = 0
            bellOn = 0                      // one-shot consumed by this frame
        }
        aliveCtr = aliveCtr + 1
        if aliveCtr >= 30 {                // ~240ms: reap + check if the shell exited
            aliveCtr = 0
            if waitChild(childPid) != 0 { i = 2000000000 }   // exited -> stop; shim sees EOF, closes window
        }
        sleepUs(0, 8000)                   // ~8ms poll
        i = i + 1
    }
    emit 0
}

// Entry when run.k is the build target directly. `-i` = interactive bridge mode
// (the GUI shim runs `kryoterm -i`); otherwise a one-shot demo session.
just run {
    let n = argCount()
    if n >= 1 && arg(0) == "-i" {
        kryoterm_interactive("/bin/zsh", 104, 30)
    } else {
        print("kryoterm — pure-Krypton terminal (live PTY engine)")
        print("--------------------------------------------------")
        kryoterm_loop("uname -srm; pwd; echo kryoterm-ok")
        print("--------------------------------------------------")
    }
}
