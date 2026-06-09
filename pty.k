// pty.k — stem PTY engine (pure Krypton, macOS).
//
// Spawns a real shell on a pseudo-terminal and talks to it over the master fd.
// Built on the macho backend's native pty/fd syscall builtins (no C, no libc):
//   ptyMaster(ptmxPath)        open /dev/ptmx + grant + unlock -> master fd
//   ptySlaveName(master)       ioctl TIOCPTYGNAME -> slave path ("/dev/ttysNNN")
//   ptyForkExec(slave, shell)  fork; child becomes the shell on the slave; parent
//                              gets the child pid
//   fdRead(fd, n) / fdWrite(fd, s, len) / fdClose(fd)   read/write/close any fd
//
// This is what turns stem from an echo box into a real terminal: a live
// interactive shell whose output streams back through term.k's grid driver.

module stem_pty

// ptyOpen(shellPath) — allocate a pty, spawn `shellPath` on its slave, return
// the master fd. Read the shell's output with ptyRead(m); send it input with
// ptyWrite(m, s).
func ptyOpen(shellPath) {
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    ptyForkExec(slave, shellPath)
    emit m
}

// ptyRead(m, n) — read up to n bytes of the shell's output (blocks until some
// data is available; returns "" at EOF after the child exits).
func ptyRead(m, n) {
    emit fdRead(m, n)
}

// ptyWrite(m, s) — send keystrokes/commands to the shell. Returns bytes written.
func ptyWrite(m, s) {
    emit fdWrite(m, s, len(s))
}

func ptyClose(m) {
    emit fdClose(m)
}

// ptySetNonblock(m) — switch the master to non-blocking: ptyRead then returns ""
// immediately when no output is pending (instead of blocking). Use for a
// poll/render loop that must also accept keystrokes.
func ptySetNonblock(m) {
    emit fdSetNonblock(m)
}

// ptyDrain(m, polls) — poll-read the master `polls` times at 5ms spacing,
// concatenating everything available. On a non-blocking master an empty read
// means "nothing right now"; the 5ms pace (sleepNs) lets slow command output
// land without busy-spinning. polls*5ms = total wait window (e.g. 400 -> ~2s).
// Returns the accumulated output for term.k's renderGrid.
func ptyDrain(m, polls) {
    let sb = sbNew()
    let i = 0
    while i < polls {
        let chunk = fdRead(m, 4096)
        if len(chunk) > 0 { sb = sbAppend(sb, chunk) }
        sleepUs(0, 5000)
        i += 1
    }
    emit sbToString(sb)
}
