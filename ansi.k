// ansi.k — stem ANSI/VT escape-sequence parser (pure Krypton).
//
// The terminal CORE, platform-independent: it turns a raw child byte stream
// into clean printable text by recognizing and consuming escape sequences
// (CSI `ESC [ … letter`, OSC `ESC ] … BEL/ST`, and 2-byte `ESC x`). This is the
// Krypton port of terk/brain's AnsiParser::feed classification step.
//
// Phase 4 will grow this into a full grid driver (cursor moves, SGR colors,
// clear, scrollback). v1 just strips escapes so a child's output renders
// without control-code garbage — already an upgrade over phase 0's raw echo.
//
// No C, no FFI: only charCode/substring/len/sbAppend, all native macho/elf
// builtins. Verified on macOS arm64.

module stem_ansi

// NOTE: module-level `let` does not survive the import boundary on the native
// pipeline (stateless-module convention), so ESC (27) / BEL (7) are inlined.

// isLetter(code) — A-Z or a-z (CSI final byte is a letter).
func _isLetter(c) {
    emit (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}

// stripAnsi(s) — return s with ANSI escape sequences removed. Control bytes
// other than \n \r \t are dropped too, so raw child output renders cleanly.
func stripAnsi(s) {
    let out = sbNew()
    let n = len(s)
    let i = 0
    while i < n {
        let c = charCode(substring(s, i, i + 1))
        if c == 27 {
            // Need a second byte to know the sequence kind.
            if i + 1 >= n { i = n }
            else {
                let k = charCode(substring(s, i + 1, i + 2))
                if k == 91 {            // '[' → CSI: skip until a letter final byte
                    let j = i + 2
                    while j < n && _isLetter(charCode(substring(s, j, j + 1))) == 0 {
                        j = j + 1
                    }
                    i = j + 1           // past the final letter
                } else {
                    if k == 93 {        // ']' → OSC: skip until BEL or ESC\ (ST)
                        let j = i + 2
                        while j < n && charCode(substring(s, j, j + 1)) != 7 {
                            // ST = ESC '\' (92)
                            if charCode(substring(s, j, j + 1)) == 27 && j + 1 < n && charCode(substring(s, j + 1, j + 2)) == 92 {
                                j = j + 1
                                i = j + 1
                                j = n + 1   // signal handled
                            } else { j = j + 1 }
                        }
                        if j <= n { i = j + 1 } else { i = j }   // BEL case: past BEL
                    } else {            // ESC x (2-byte sequence): skip both
                        i = i + 2
                    }
                }
            }
        } else {
            // Printable + the whitespace we keep; drop other C0 controls.
            if c >= 32 || c == 10 || c == 9 || c == 13 {
                out = sbAppend(out, substring(s, i, i + 1))
            }
            i = i + 1
        }
    }
    emit sbToString(out)
}
