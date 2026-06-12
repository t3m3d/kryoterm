// gui.ks — run stem in its Cocoa window. The terminal engine is pure Krypton
// (run.k -i: pty + ANSI grid + colour + UTF-8 + interactive bridge); stem-gui
// is the temporary Obj-C window shim, which spawns `stem -i` on a pty, draws its
// frames, and forwards keystrokes. Builds whatever's missing.
//   Run from the repo root:  kcc -r gui.ks
func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }

just run {
    if isExec("stem-gui") != "yes" { exec("kcc -r build_gui.ks") }
    if isExec("stem")     != "yes" { exec("kcc -r build.ks") }
    exec("./stem-gui ./stem")
}
