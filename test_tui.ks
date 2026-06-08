// test_tui.ks — assertion regression for the TUI/engine features (mouse, alt
// screen, cursor visibility/shape, bracketed paste, scrollback, truecolor).
// Pass criterion: zero FAIL lines.
import "./term.k"

func chk(name, got, want) {
  if got == want { kp("PASS " + name) }
  else { kp("FAIL " + name + " got[" + got + "] want[" + want + "]") }
}

func firstLine(s) {
  let nl = indexOf(s, fromCharCode(10))
  if nl < 0 { emit s }
  emit substring(s, 0, nl)
}

just run {
  let e = fromCharCode(27)
  let nl = fromCharCode(10)

  // mouse modes
  let st = gridNew(20, 3)
  chk("mouse init", gridMouse(st, 20, 3), "0,0")
  st = gridFeed(st, e + "[?1000h" + e + "[?1006h", 20, 3)
  chk("mouse 1000h+1006h", gridMouse(st, 20, 3), "1,1")
  st = gridFeed(st, e + "[?1002h", 20, 3)
  chk("mouse 1002h", gridMouse(st, 20, 3), "2,1")
  st = gridFeed(st, e + "[?1000l", 20, 3)
  chk("mouse 1000l off", gridMouse(st, 20, 3), "0,1")

  // alternate screen round-trip
  let a = gridNew(20, 2)
  a = gridFeed(a, "MAIN", 20, 2)
  chk("alt main", firstLine(gridRender(a, 20, 2)), "MAIN")
  a = gridFeed(a, e + "[?1049h", 20, 2)
  chk("alt entered blank", firstLine(gridRender(a, 20, 2)), "")
  a = gridFeed(a, "ALT", 20, 2)
  chk("alt content", firstLine(gridRender(a, 20, 2)), "ALT")
  a = gridFeed(a, e + "[?1049l", 20, 2)
  chk("alt restored", firstLine(gridRender(a, 20, 2)), "MAIN")
  chk("alt no scrollback leak", gridScrolled(a, 20, 2), "")

  // cursor visibility
  let c = gridFeed(gridNew(20, 2), "AB", 20, 2)
  chk("cursor visible", gridCursor(c, 20, 2), "0,2")
  c = gridFeed(c, e + "[?25l", 20, 2)
  chk("cursor hidden", gridCursor(c, 20, 2), "9999,0")
  c = gridFeed(c, e + "[?25h", 20, 2)
  chk("cursor shown", gridCursor(c, 20, 2), "0,2")

  // cursor shape (DECSCUSR)
  let s2 = gridNew(20, 2)
  s2 = gridFeed(s2, e + "[5 q", 20, 2)
  chk("shape bar", gridShape(s2, 20, 2), 1)
  s2 = gridFeed(s2, e + "[2 q", 20, 2)
  chk("shape block", gridShape(s2, 20, 2), 2)
  s2 = gridFeed(s2, e + "[3 q", 20, 2)
  chk("shape underline", gridShape(s2, 20, 2), 3)

  // bracketed paste mode
  let pm = gridNew(20, 2)
  chk("paste init", gridPaste(pm, 20, 2), 0)
  pm = gridFeed(pm, e + "[?2004h", 20, 2)
  chk("paste on", gridPaste(pm, 20, 2), 1)
  pm = gridFeed(pm, e + "[?2004l", 20, 2)
  chk("paste off", gridPaste(pm, 20, 2), 0)

  // focus reporting (DECSET 1004)
  let fm = gridNew(20, 2)
  chk("focus init", gridFocus(fm, 20, 2), 0)
  fm = gridFeed(fm, e + "[?1004h", 20, 2)
  chk("focus on", gridFocus(fm, 20, 2), 1)
  fm = gridFeed(fm, e + "[?1004l", 20, 2)
  chk("focus off", gridFocus(fm, 20, 2), 0)

  // scrollback capture (5 lines into a 3-row grid -> 3 scroll off)
  let sb = gridFeed(gridNew(10, 3), "L1" + nl + "L2" + nl + "L3" + nl + "L4" + nl + "L5" + nl, 10, 3)
  chk("scrollback captured", gridScrolled(sb, 10, 3), "L1" + nl + "L2" + nl + "L3" + nl)
  chk("scrollback live tail", firstLine(gridRender(sb, 10, 3)), "L4")

  // truecolor fold to xterm-256
  let tc = renderGrid(e + "[48;2;200;50;50m" + "X" + e + "[0m", 8, 1)
  chk("truecolor folds to 48;5;167", contains(tc, "48;5;167"), 1)

  kp("--- done ---")
}
