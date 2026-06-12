// build_linux.ks — build stem on Linux (x86_64 / aarch64).
//
// Pure-Krypton build path: kcc compiles run.k to a static, syscall-only ELF.
// No gcc/cmake/clang at user-build time once kcc is bootstrapped.
//
// Usage:
//   kcc -r build_linux.ks            # builds ./stem from run.k
//   kcc -r build_linux.ks --run      # ... then runs it once
//   kcc -r build_linux.ks --ks       # builds the KryptScript entry (run.ks)
//
// kcc resolution: `kcc` on PATH, else the Linux driver seed in $KRYPTON_ROOT
// (default ../krypton).

func has(cmd) { emit trim(exec("command -v " + cmd + " >/dev/null 2>&1 && echo yes || echo no")) }
func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }

just run {
    let kcc = "kcc"
    if has("kcc") != "yes" {
        let root = environ("KRYPTON_ROOT")
        if root == "" { root = "../krypton" }
        let seedPath = root + "/bootstrap/kcc_driver_linux_x86_64"
        if isExec(seedPath) != "yes" {
            kp("build_linux.ks: no 'kcc' on PATH and no " + seedPath)
            kp("  Set KRYPTON_ROOT to your krypton checkout, or install Krypton.")
            emit 1
        }
        kcc = "env KRYPTON_ROOT=\"" + root + "\" \"" + seedPath + "\""
    }

    let src = "run.k"
    let run = 0
    let i = 0
    while i < argCount() {
        let a = arg(toStr(i))
        if a == "--run" { run = 1 }
        if a == "--ks"  { src = "run.ks" }
        i = i + 1
    }

    kp("build_linux.ks: " + src + " -> stem")
    let out = exec(kcc + " --native " + src + " -o stem 2>&1")
    if out != "" { kp(out) }
    if isExec("stem") != "yes" {
        kp("build_linux.ks: build failed — stem not produced")
        emit 1
    }
    kp("build_linux.ks: built stem (" + trim(exec("wc -c < stem | tr -d ' '")) + " bytes, static ELF)")
    if run == 1 { exec("./stem") }
}
