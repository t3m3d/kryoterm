// build_app.ks — assemble stem.app (Finder-launchable bundle).
//
// Wraps the temp Obj-C shim (stem-gui) + the pure-Krypton engine (stem) into a
// .app with an Info.plist. Run from the repo root:  kcc -r build_app.ks
// (For the pure-Krypton, no-Obj-C bundle use build_objk.ks instead.)

func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }
func isFile(p) { emit trim(exec("test -f \"" + p + "\" && echo yes || echo no")) }

just run {
    let app = "stem.app"

    if isExec("stem-gui") != "yes" { exec("kcc -r build_gui.ks") }
    if isExec("stem") != "yes" {
        kp("build_app.ks: ./stem missing — build it first:  kcc -r build.ks")
        emit 1
    }
    if isFile("stem.icns") != "yes" { exec("kcc -r make_icon.ks") }

    exec("rm -rf \"" + app + "\"")
    exec("mkdir -p \"" + app + "/Contents/MacOS\" \"" + app + "/Contents/Resources\"")
    exec("cp stem-gui stem \"" + app + "/Contents/MacOS/\"")
    exec("cp stem.icns \"" + app + "/Contents/Resources/\" 2>/dev/null")

    let q = fromCharCode(34)
    let plist = "<?xml version=" + q + "1.0" + q + " encoding=" + q + "UTF-8" + q + "?>\n" +
        "<!DOCTYPE plist PUBLIC " + q + "-//Apple//DTD PLIST 1.0//EN" + q + " " + q + "http://www.apple.com/DTDs/PropertyList-1.0.dtd" + q + ">\n" +
        "<plist version=" + q + "1.0" + q + ">\n<dict>\n" +
        "  <key>CFBundleName</key><string>stem</string>\n" +
        "  <key>CFBundleDisplayName</key><string>stem</string>\n" +
        "  <key>CFBundleExecutable</key><string>stem-gui</string>\n" +
        "  <key>CFBundleIconFile</key><string>stem</string>\n" +
        "  <key>CFBundleIdentifier</key><string>org.krypton.stem</string>\n" +
        "  <key>CFBundleVersion</key><string>1.0</string>\n" +
        "  <key>CFBundleShortVersionString</key><string>1.0</string>\n" +
        "  <key>CFBundlePackageType</key><string>APPL</string>\n" +
        "  <key>LSMinimumSystemVersion</key><string>11.0</string>\n" +
        "  <key>NSHighResolutionCapable</key><true/>\n" +
        "  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>\n" +
        "</dict>\n</plist>\n"
    writeFile(app + "/Contents/Info.plist", plist)

    exec("codesign -s - -f \"" + app + "/Contents/MacOS/stem\" >/dev/null 2>&1")
    exec("codesign -s - -f \"" + app + "/Contents/MacOS/stem-gui\" >/dev/null 2>&1")
    exec("codesign -s - -f \"" + app + "\" >/dev/null 2>&1")

    kp("built " + app + " - double-click in Finder, or:  open " + app)
}
