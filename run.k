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

// Entry when run.k is the build target directly.
just run {
    print("kryoterm — pure-Krypton terminal (live PTY engine)")
    print("--------------------------------------------------")
    kryoterm_loop("uname -srm; pwd; echo kryoterm-ok")
    print("--------------------------------------------------")
}
