import "./term.k"
just run {
  let esc = fromCharCode(27)
  let nl = fromCharCode(10)
  kp("=== plain 'ab' 5x2 ===");                kp("[" + renderGrid("ab", 5, 2) + "]")
  kp("=== CUP ESC[2;6H 'Hi' (Hi at row1 col5) ==="); kp("[" + renderGrid(esc + "[2;6H" + "Hi", 12, 3) + "]")
  kp("=== text + newline ===");                kp("[" + renderGrid("line1" + nl + "line2", 12, 3) + "]")
  kp("=== CR overwrite XXXXX\\rab -> abXXX ==="); kp("[" + renderGrid("XXXXX" + fromCharCode(13) + "ab", 10, 1) + "]")
  kp("=== cursor up: AB\\nCD ESC[1A Z -> Z over A ==="); kp("[" + renderGrid("AB" + nl + "CD" + esc + "[1A" + "Z", 6, 2) + "]")
  kp("=== erase ESC[2J wipes ===");            kp("[" + renderGrid("junk" + esc + "[2J", 8, 2) + "]")
}
