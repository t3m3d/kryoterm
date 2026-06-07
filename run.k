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
    let m = ptyOpen(shellPath)
    ptySetNonblock(m)
    fdSetNonblock(0)                       // stdin (keys from the window)
    let st = gridNew(cols, rows)
    let ff = fromCharCode(12)              // frame TERMINATOR (suffix): the shim
                                           // renders the bytes preceding each \f,
                                           // so \f must END a frame (not start it)
                                           // or the display lags one frame behind.
    // NOTE: a loop-invariant `while go == 1` MISCOMPILES on the macho backend
    // (the loop body never runs). Use a large bounded counter that changes each
    // iteration (2e9 * 8ms ≈ months — effectively unbounded for a session).
    let i = 0
    while i < 2000000000 {
        let keys = fdRead(0, 4096)
        if len(keys) > 0 { fdWrite(m, keys, len(keys)) }
        let out = fdRead(m, 65536)
        if len(out) > 0 {
            st = gridFeed(st, out, cols, rows)
            let frame = gridRender(st, cols, rows) + ff
            fdWrite(1, frame, len(frame))
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
        kryoterm_interactive("/bin/zsh", 80, 24)
    } else {
        print("kryoterm — pure-Krypton terminal (live PTY engine)")
        print("--------------------------------------------------")
        kryoterm_loop("uname -srm; pwd; echo kryoterm-ok")
        print("--------------------------------------------------")
    }
}
