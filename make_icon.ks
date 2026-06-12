// make_icon.ks — render stem.icns from make_icon.m (each size drawn crisp).
// Run from the repo root:  kcc -r make_icon.ks
func render(set, sz, name) {
    exec("./make_icon \"" + set + "/" + name + "\" " + sz + " 2>/dev/null")
}

just run {
    let c = exec("clang -framework Cocoa -fobjc-arc -O2 -w make_icon.m -o make_icon 2>&1")
    if c != "" { kp(c) }

    let set = "/tmp/stem.iconset"
    exec("rm -rf \"" + set + "\"")
    exec("mkdir -p \"" + set + "\"")

    render(set, "16",   "icon_16x16.png")
    render(set, "32",   "icon_16x16@2x.png")
    render(set, "32",   "icon_32x32.png")
    render(set, "64",   "icon_32x32@2x.png")
    render(set, "128",  "icon_128x128.png")
    render(set, "256",  "icon_128x128@2x.png")
    render(set, "256",  "icon_256x256.png")
    render(set, "512",  "icon_256x256@2x.png")
    render(set, "512",  "icon_512x512.png")
    render(set, "1024", "icon_512x512@2x.png")

    exec("iconutil -c icns \"" + set + "\" -o stem.icns")
    kp("built stem.icns (" + trim(exec("du -h stem.icns | cut -f1")) + ")")
}
