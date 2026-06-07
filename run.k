// run.k — kryoterm core (phase 0).
//
// Phase 0 = bootstrap: prove kryoterm builds against Krypton, spawn one
// child command via shellRun, echo its output, exit cleanly. No
// window yet (waits on x11.k Phase B), no PTY yet (waits on forkpty
// builtin in elf.k), no rendering yet (waits on x11.k Phase C).
//
// The function shapes here (kryoterm_spawn, kryoterm_render, kryoterm_loop)
// are the ones the later phases will fill in. Today they're stubs;
// run.ks calls into them so the .ks-side entry point doesn't need to
// change as the .k side gains capability.

module kryoterm

// ANSI/VT parser — the pure-Krypton terminal core (platform-independent).
// Phase 0 uses it to strip escape sequences so child output echoes cleanly;
// later phases grow it into a full grid driver. Verified on macOS arm64.
import "./ansi.k"

// Phase 0: run `cmd` via shellRun, return its stdout as a string.
// shellRun is already in elf.k as a native syscall builtin (no C).
// Phase 3 will replace this with a real forkpty + read loop so we
// can drive interactive TUI programs (ncurses, vim, etc.).
func kryoterm_spawn(cmd) {
    emit shellRun(cmd)
}

// Phase 0: dump `output` to stdout. Phase 2 will swap this for
// stdlib/x11.k ImageText8 calls so output appears in the kryoterm
// window instead of the parent terminal.
func kryoterm_render(output) {
    print(stripAnsi(output))
    emit 0
}

// Phase 0: spawn the command, render the result, exit. Phase 3+
// turns this into a real read/render loop that polls the PTY and
// the X11 event queue.
func kryoterm_loop(cmd) {
    let out = kryoterm_spawn(cmd)
    kryoterm_render(out)
    emit 0
}

// Phase 0 entry — invoked directly when run.k is the build target.
// run.ks (KryptScript front-end) calls kryoterm_loop with a parsed
// command instead.
just run {
    print("kryoterm phase 0 — bootstrap")
    print("--------------------------")
    kryoterm_loop("echo 'hello from a kryoterm child process'")
    print("--------------------------")
    print("(phase 1 = x11 window  |  phase 2 = render in window")
    print(" phase 3 = real PTY    |  phase 4 = ANSI + scrollback)")
}
