// pty.k — kryoterm PTY engine (pure Krypton, macOS).
//
// Spawns a real shell on a pseudo-terminal and talks to it over the master fd.
// Built on the macho backend's native pty/fd syscall builtins (no C, no libc):
//   ptyMaster(ptmxPath)        open /dev/ptmx + grant + unlock -> master fd
//   ptySlaveName(master)       ioctl TIOCPTYGNAME -> slave path ("/dev/ttysNNN")
//   ptyForkExec(slave, shell)  fork; child becomes the shell on the slave; parent
//                              gets the child pid
//   fdRead(fd, n) / fdWrite(fd, s, len) / fdClose(fd)   read/write/close any fd
//
// This is what turns kryoterm from an echo box into a real terminal: a live
// interactive shell whose output streams back through term.k's grid driver.

module kryoterm_pty

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
