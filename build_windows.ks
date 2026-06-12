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
        // POSIX `command -v` doesn't exist on cmd.exe -- it prints
        // "The system cannot find the path specified." to stdout (NOT
        // stderr), which 2>/dev/null can't filter, so the resolution
        // would land on a garbage string and every later exec would
        // fail with "'The' is not recognized".  Use `where` (Windows
        // built-in) which prints the path or returns non-zero with no
        // stdout if the binary isn't found.
        let onPath = trim(exec("where kcc.exe 2>NUL"))
        if onPath != "" { kcc = onPath } else { kcc = "C:/krypton/kcc.exe" }
    }
    let out = "stem.exe"
    let manifest = "stem_win.exe.manifest"

    kp("[1/3] kcc compile -> " + out)
    // Krypton's exec() on Windows wraps the command in `cmd /c "..."`; if WE
    // also quote the kcc path here (`"C:/krypton/kcc.exe"`), cmd sees
    // `cmd /c ""C:/krypton/kcc.exe" stem_win.ks ..."` and the double-double-
    // quote at the start makes cmd reinterpret "stem_win.ks" as the command
    // name -> "'The' is not recognized" and no stem.exe gets produced.
    // Leave kcc unquoted (path is always Windows-friendly, no spaces).
    // No 2>&1 -- on Windows, Krypton's exec wraps in cmd /c "...", and
    // trailing `2>&1` against that wrapper made cmd reinterpret kcc's stderr
    // text as a fresh command ("'The' is not recognized ...").
    let c = exec(kcc + " stem_win.ks -o " + out)
    if c != "" { kp(c) }
    // Fail loudly if the compile didn't drop the binary, rather than
    // pretending later steps succeeded.
    let check = trim(exec("test -f " + out + " && echo ok || echo no"))
    if check != "ok" { kp("FAIL: " + out + " not produced -- aborting")  exit(1) }

    kp("[2/3] patch PE Subsystem CUI->GUI")
    // PE header offset = u32 LE at file offset 0x3c (60). Subsystem u16 lives at
    // peOff + 24 (COFF header) + 0x44 (offset of Subsystem in the optional hdr).
    // Krypton's exec uses cmd.exe on Windows -- it doesn't expand
    // POSIX `$((x+y))` (dd would see the literal `$((...))` and reject
    // it) and it mangles the printf single-quoted-escape `'\\002\\000'`
    // (printf gets the wrong bytes, dd appears to succeed but no byte
    // gets flipped).  Force a real shell with `bash -c "..."` so the
    // pipe + printf escapes + arithmetic all work.
    let peOff = trim(exec("bash -c \"od -An -tu4 -j60 -N4 " + out + " | tr -d ' '\""))
    let seek = toStr(toInt(peOff) + 92)
    exec("bash -c \"printf '\\\\002\\\\000' | dd of=" + out + " bs=1 seek=" + seek + " conv=notrunc 2>/dev/null\"")
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
