// build_objk.ks — build the PURE-KRYPTON stem GUI (objk FFI). No Obj-C source.
//
// Window + custom NSView drawRect grid + keyDown->pty + NSTimer/pump loop are
// all Krypton (stem.ks) on the objk Objective-C FFI. The built app links only
// libobjc + Foundation + AppKit — verify: otool -L dist/stem.app/Contents/MacOS/stem
//
// objk shipped in Krypton 2.4.0, so the installed (released) kcc builds it.
// KRYPTON_ROOT optionally points at a dev checkout
// (compiler/macos_arm64/{kcc-arm64,macho_host} + stdlib/cocoa.k + headers);
// default: sibling ../krypton. Run from the repo root:  kcc -r build_objk.ks

func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }
func isFile(p) { emit trim(exec("test -f \"" + p + "\" && echo yes || echo no")) }
func newer(a, b) { emit trim(exec("test \"" + a + "\" -nt \"" + b + "\" && echo yes || echo no")) }

just run {
    let root = environ("KRYPTON_ROOT")
    if root == "" { root = "../krypton" }
    let fe   = root + "/compiler/macos_arm64/kcc-arm64"
    let host = root + "/compiler/macos_arm64/macho_host"
    let backend = root + "/compiler/macos_arm64/macho_arm64_self.k"

    if isFile(root + "/stdlib/cocoa.k") != "yes" {
        kp("build_objk.ks: KRYPTON_ROOT='" + root + "' is not a Krypton dev checkout.")
        kp("  set KRYPTON_ROOT=/path/to/krypton (needs compiler/macos_arm64 + stdlib + headers)")
        emit 1
    }
    if isExec(fe) != "yes" {
        kp("build_objk.ks: missing " + fe)
        emit 1
    }

    // Ensure the macho codegen host is built from the current backend.
    if isExec(host) != "yes" {
        kp("==> building macho_host from macho_arm64_self.k")
        exec("kcc --native \"" + backend + "\" -o \"" + host + "\"")
    } else {
        if newer(backend, host) == "yes" {
            kp("==> rebuilding macho_host (backend changed)")
            exec("kcc --native \"" + backend + "\" -o \"" + host + "\"")
        }
    }

    kp("==> compiling stem.ks (objk, pure Krypton)")
    exec("env KRYPTON_ROOT=\"" + root + "\" \"" + fe + "\" stem.ks > /tmp/stem.kir")
    exec("\"" + host + "\" --ir /tmp/stem.kir /tmp/stem.bin >/dev/null")

    let app = "dist/stem.app"
    exec("rm -rf \"" + app + "\"")
    exec("mkdir -p \"" + app + "/Contents/MacOS\" \"" + app + "/Contents/Resources\"")
    exec("cp /tmp/stem.bin \"" + app + "/Contents/MacOS/stem\"")
    exec("chmod +x \"" + app + "/Contents/MacOS/stem\"")
    if isFile("stem.icns") == "yes" { exec("cp stem.icns \"" + app + "/Contents/Resources/stem.icns\"") }

    let q = fromCharCode(34)
    let plist = "<?xml version=" + q + "1.0" + q + " encoding=" + q + "UTF-8" + q + "?>\n" +
        "<!DOCTYPE plist PUBLIC " + q + "-//Apple//DTD PLIST 1.0//EN" + q + " " + q + "http://www.apple.com/DTDs/PropertyList-1.0.dtd" + q + ">\n" +
        "<plist version=" + q + "1.0" + q + "><dict>\n" +
        "  <key>CFBundleName</key><string>stem</string>\n" +
        "  <key>CFBundleDisplayName</key><string>stem</string>\n" +
        "  <key>CFBundleExecutable</key><string>stem</string>\n" +
        "  <key>CFBundleIdentifier</key><string>org.krypton-lang.stem</string>\n" +
        "  <key>CFBundleIconFile</key><string>stem</string>\n" +
        "  <key>CFBundlePackageType</key><string>APPL</string>\n" +
        "  <key>CFBundleShortVersionString</key><string>2.0.0</string>\n" +
        "  <key>LSMinimumSystemVersion</key><string>11.0</string>\n" +
        "  <key>NSHighResolutionCapable</key><true/>\n" +
        "  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>\n" +
        "</dict></plist>\n"
    writeFile(app + "/Contents/Info.plist", plist)

    exec("codesign -s - -f \"" + app + "/Contents/MacOS/stem\" >/dev/null 2>&1")
    exec("codesign -s - -f \"" + app + "\" >/dev/null 2>&1")
    kp("==> built " + app + " (pure Krypton, no Obj-C source). Run:  open " + app)
}
