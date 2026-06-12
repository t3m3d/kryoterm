// build.ks — build stem (macOS arm64 / Linux x86_64). Pure Krypton: the kcc
// driver compiles run.ks to a native, syscall-only binary. No gcc/clang/cmake
// at build time once kcc itself is installed.
//
// Usage:
//   kcc -r build.ks             # build ./stem from run.ks (KryptScript entry)
//   kcc -r build.ks --run       # ... then run it once
//   kcc -r build.ks --k         # build run.k directly instead of run.ks
//
// kcc resolution: prefer `kcc` on PATH, else the platform driver seed in a
// krypton checkout ($KRYPTON_ROOT, default ../krypton).

func has(cmd) { emit trim(exec("command -v " + cmd + " >/dev/null 2>&1 && echo yes || echo no")) }
func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }

just run {
    let os = trim(exec("uname -s"))
    let seed = "kcc_driver_linux_x86_64"
    if os == "Darwin" { seed = "kcc_driver_macos_aarch64" }

    let kcc = "kcc"
    if has("kcc") != "yes" {
        let root = environ("KRYPTON_ROOT")
        if root == "" { root = "../krypton" }
        let seedPath = root + "/bootstrap/" + seed
        if isExec(seedPath) != "yes" {
            kp("build.ks: no 'kcc' on PATH and no " + seedPath)
            kp("  Install Krypton (brew install t3m3d/krypton/krypton) or set KRYPTON_ROOT.")
            emit 1
        }
        kcc = "env KRYPTON_ROOT=\"" + root + "\" \"" + seedPath + "\""
    }

    let src = "run.ks"
    let run = 0
    let i = 0
    while i < argCount() {
        let a = arg(toStr(i))
        if a == "--run" { run = 1 }
        if a == "--k"   { src = "run.k" }
        if a == "-h"     { kp("usage: kcc -r build.ks [--run] [--k]"); emit 0 }
        if a == "--help" { kp("usage: kcc -r build.ks [--run] [--k]"); emit 0 }
        i = i + 1
    }

    kp("build.ks: " + src + " -> stem")
    let out = exec(kcc + " --native " + src + " -o stem 2>&1")
    if out != "" { kp(out) }
    if os == "Darwin" { exec("codesign -s - -f stem >/dev/null 2>&1") }

    if isExec("stem") != "yes" {
        kp("build.ks: build failed — stem not produced")
        emit 1
    }
    kp("build.ks: built stem (" + trim(exec("wc -c < stem | tr -d ' '")) + " bytes)")
    if run == 1 { exec("./stem") }
}
