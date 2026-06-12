// build_dmg.ks — build the shippable stem DMG (the cask artifact) with the
// RELEASED Krypton kcc. No dev checkout, no Obj-C: stem.ks builds C-free on the
// objk FFI that shipped in Krypton 2.4.0.
//
// Usage:  kcc -r build_dmg.ks <version>          # e.g. 0.12.11
//
// Toolchain: uses `kcc` on PATH. Once Homebrew `krypton` is >= 2.4.0 its wrapper
// sets KRYPTON_ROOT to a libexec that carries objk, so no extra config is needed.
// Until then, point KRYPTON_ROOT at a krypton 2.4.0 install (or the extracted
// release tarball): KRYPTON_ROOT=/path/to/krypton-2.4.0 kcc -r build_dmg.ks <v>

func sh(c) { emit trim(exec(c)) }

just run {
    if argCount() == 0 || arg("0") == "" {
        kp("usage: kcc -r build_dmg.ks <version>   (e.g. 0.12.11)")
        emit 1
    }
    let ver = arg("0")

    // 1. Build the pure-Krypton objk app with the (released) kcc. build_objk.ks
    //    honors KRYPTON_ROOT; pass ours through so the child kcc sees it.
    kp("==> building stem.app (objk, released kcc)")
    let kr = environ("KRYPTON_ROOT")
    let pre = ""
    if kr != "" { pre = "KRYPTON_ROOT=\"" + kr + "\" " }
    exec(pre + "kcc -r build_objk.ks")

    // 2. Fail closed if it isn't C-free.
    let nonsys = sh("otool -L dist/stem.app/Contents/MacOS/stem | tail -n +2 | grep -cv 'libobjc\\|Foundation\\|AppKit'")
    if nonsys != "0" {
        kp("build_dmg.ks: ABORT — stem.app links " + nonsys + " non-system dylib(s); not C-free")
        emit 1
    }
    kp("    stem.app is C-free (0 non-system links)")

    // 3. Stage app + /Applications drag target, build a compressed DMG.
    let stage = "/tmp/stem-dmg-stage"
    exec("rm -rf \"" + stage + "\"")
    exec("mkdir -p \"" + stage + "\"")
    exec("cp -R dist/stem.app \"" + stage + "/stem.app\"")
    exec("ln -s /Applications \"" + stage + "/Applications\"")

    exec("mkdir -p dist")
    let out = "dist/stem-" + ver + ".dmg"
    exec("rm -f \"" + out + "\"")
    let r = exec("hdiutil create -volname stem -srcfolder \"" + stage + "\" -ov -format UDZO \"" + out + "\" 2>&1")
    if indexOf(r, "created:") < 0 { kp(r) }
    exec("rm -rf \"" + stage + "\"")

    kp("==> built " + out + " (" + sh("du -h \"" + out + "\" | cut -f1") + ")")
    kp("    sha256: " + sh("shasum -a 256 \"" + out + "\" | cut -d' ' -f1"))
    kp("    next: gh release upload " + ver + " " + out + " --repo t3m3d/stem; bump Casks/stem.rb (version+sha256)")
}
