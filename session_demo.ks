// session_demo.ks — kryoterm end-to-end: spawn a real shell on a pty, capture
// its output, render it through the grid. The full pipeline in pure Krypton.
import "./pty.k"
import "./term.k"
just run {
  let nl = fromCharCode(10)
  let m = ptyOpen("/bin/sh")
  ptyWrite(m, "echo kryoterm-line-1" + nl + "echo kryoterm-line-2" + nl + "exit" + nl)
  let sb = sbNew()
  let i = 0
  while i < 12 {
    let out = ptyRead(m, 4096)
    if len(out) > 0 { sb = sbAppend(sb, out) }
    i = i + 1
  }
  ptyClose(m)
  kp("=== rendered through term.k grid (60x12) ===")
  kp(renderGrid(sbToString(sb), 60, 12))
}
