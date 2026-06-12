// build_windows.ks — build stem on Windows (x86_64).
//
// Pure-Krypton + Win32 path: kcc compiles stem_win.ks to a native PE linked
// against the existing IAT thunks (user32, gdi32, comctl32, kernel32, dwmapi).
// No gcc/cmake/clang. After kcc emits the PE we patch the
// IMAGE_OPTIONAL_HEADER.Subsystem byte CUI(3) -> GUI(2) so Explorer launches
// don't show a console window (kcc lacks a --subsystem flag).
//
// The old build_windows.sh embedded a python3 heredoc for the byte patch; this
// .ks does it with od + dd (no python). KryptScript strings are NUL-terminated
// so the binary can't be patched via readFile/writeFile — hence the shell pokes.
//
// Usage:
//   kcc -r build_windows.ks            # builds ./stem.exe from stem_win.ks
//   kcc -r build_windows.ks --run      # ... then launches it once
// Requires kcc(.exe) on PATH (or KCC env var) on a POSIX-ish shell (od/dd).
// NOTE: build path is Windows-only — not runnable on macOS/Linux.

func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }

just run {
    let kcc = environ("KCC")
    if kcc == "" {
        let onPath = trim(exec("command -v kcc.exe 2>/dev/null"))
        if onPath != "" { kcc = onPath } else { kcc = "C:/krypton/kcc.exe" }
    }
    let out = "stem.exe"
    let manifest = "stem_win.exe.manifest"

    kp("[1/3] kcc compile -> " + out)
    let c = exec("\"" + kcc + "\" stem_win.ks -o \"" + out + "\" 2>&1")
    if c != "" { kp(c) }

    kp("[2/3] patch PE Subsystem CUI->GUI")
    // PE header offset = u32 LE at file offset 0x3c (60). Subsystem u16 lives at
    // peOff + 24 (COFF header) + 0x44 (offset of Subsystem in the optional hdr).
    let peOff = trim(exec("od -An -tu4 -j60 -N4 \"" + out + "\" | tr -d ' '"))
    exec("printf '\\002\\000' | dd of=\"" + out + "\" bs=1 seek=$((" + peOff + "+92)) conv=notrunc 2>/dev/null")
    kp("  subsystem -> 2 (Windows GUI)")

    kp("[3/3] copy manifest sidecar")
    exec("cp \"" + manifest + "\" \"" + out + ".manifest\"")
    kp("  " + out + ".manifest")
    kp("")
    kp("OK -> " + out)

    let i = 0
    while i < argCount() {
        if arg(toStr(i)) == "--run" { exec("\"./" + out + "\"") }
        i = i + 1
    }
}
