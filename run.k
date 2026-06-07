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
    let nl = fromCharCode(10)
    // Spawn a plain /bin/sh, then have it replace itself with an rc-free zsh
    // (`zsh -f`) — a clean prompt, no .zshrc/powerlevel10k redraw storm. (The
    // ptyForkExec builtin can't pass argv flags, so we drive it via the shell.)
    let m = ptyOpen("/bin/sh")
    // `clear` wipes the echoed bootstrap line (ESC[2J, which the grid honours),
    // then exec replaces sh with an rc-free zsh — so the window opens straight to
    // a clean `%` prompt, no sh→zsh transition scrollback.
    let boot = "clear; exec /bin/zsh -f" + nl
    fdWrite(m, boot, len(boot))            // BLOCKING write (before nonblock) so
                                           // the bootstrap line can't be dropped
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
    let i = 0
    while i < 2000000000 {
        let keys = fdRead(0, 4096)
        if len(keys) > 0 { fdWrite(m, keys, len(keys)) }
        let out = fdRead(m, 65536)
        if len(out) > 0 {
            // A pty read can split an escape or UTF-8 char; feed only up to the
            // last COMPLETE unit and carry the remainder to the next read, or the
            // grid corrupts (e.g. kryofetch's colour/box-drawing output).
            let chunk = pending + out
            let cut = gridSafeLen(chunk)
            if cut > 0 { st = gridFeed(st, substring(chunk, 0, cut), cols, rows) }
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
            let frame = gridRender(st, cols, rows) + ff
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
        kryoterm_interactive("/bin/zsh", 80, 28)
    } else {
        print("kryoterm — pure-Krypton terminal (live PTY engine)")
        print("--------------------------------------------------")
        kryoterm_loop("uname -srm; pwd; echo kryoterm-ok")
        print("--------------------------------------------------")
    }
}
