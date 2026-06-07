// session_demo.ks — kryoterm end-to-end: spawn a real shell on a pty, run a few
// commands, render the live output through term.k's grid. Pure Krypton, no C.
import "./pty.k"
import "./term.k"
just run {
  let nl = fromCharCode(10)
  let m = ptyOpen("/bin/zsh")
  ptySetNonblock(m)
  ptyDrain(m, 120)                       // let the shell boot (~600ms)
  ptyWrite(m, "uname -srm" + nl)
  ptyWrite(m, "pwd" + nl)
  ptyWrite(m, "echo kryoterm-session-ok; exit" + nl)
  let raw = ptyDrain(m, 300)             // collect output (~1.5s)
  ptyClose(m)
  kp("=== kryoterm: live shell rendered through the grid (80x20) ===")
  kp(renderGrid(raw, 80, 20))
}
