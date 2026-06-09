// run.ks — stem KryptScript front-end.
//
// User-facing entry point. Parses argv, loads config (later), picks
// the command to spawn, delegates to the compiled core in run.k.
//
// KryptScript (.ks) is the higher-level scripting flavour — same
// language, used for glue / config / orchestration rather than the
// performance-critical inner loop. yubikrypt does the same split:
// `yubikrypt.ks` is the entry, the heavy bits compile to native.
//
// Phase 0 just demonstrates the call shape: argv -> cmd -> spawn.

import "./run.k"

just run {
    let cmd = "echo 'hello from stem via the KryptScript entry'"
    let n = argCount()
    if n > 1 {
        cmd = arg(1)
        let i = 2
        while i < n {
            cmd = cmd + " " + arg(i)
            i += 1
        }
    }
    print("stem: spawning -> " + cmd)
    stem_loop(cmd)
}
