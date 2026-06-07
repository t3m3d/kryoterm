import "./ansi.k"
just run {
  let esc = fromCharCode(27)
  let bel = fromCharCode(7)
  kp("[CSI] [" + stripAnsi(esc + "[31m" + "RED" + esc + "[0m" + " plain") + "]")
  kp("[OSC] [" + stripAnsi(esc + "]0;mytitle" + bel + "after") + "]")
  kp("[mix] [" + stripAnsi("a" + fromCharCode(10) + "b" + esc + "[2J" + "c") + "]")
  kp("[bare][" + stripAnsi("just text, no escapes") + "]")
}
