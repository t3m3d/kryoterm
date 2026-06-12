// build_gui.ks — compile the TEMPORARY stem GUI shim (Obj-C/Cocoa).
// The terminal engine is pure Krypton; this only opens a window + draws.
// Delete once the objk GUI (stem.ks / build_objk.ks) replaces it everywhere.
// Run from the repo root:  kcc -r build_gui.ks
just run {
    let out = exec("clang -framework Cocoa -framework Contacts -framework ContactsUI -fobjc-arc -O2 -Wall gui_shim.m -o stem-gui 2>&1")
    if out != "" { kp(out) }
    let ok = exec("test -x stem-gui && echo built || echo FAILED")
    kp("build_gui.ks: " + trim(ok) + " ./stem-gui")
}
