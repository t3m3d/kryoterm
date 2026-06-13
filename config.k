// config.k — stem configuration.
//
// Loads a simple `key = value` file (with `#` comments and blank lines) from
// $STEM_CONF, else $HOME/.config/stem/stem.conf. A missing file or missing key
// falls back to the supplied default (readFile returns "" on a missing path, so
// nothing crashes when no config exists). Pure Krypton — no syscalls beyond
// readFile/environ.
module config

// Active config path: $STEM_CONF wins, else ~/.config/stem/stem.conf.
func confPath() {
    let p = environ("STEM_CONF")
    if p != "" { emit p }
    emit environ("HOME") + "/.config/stem/stem.conf"
}

// Raw config text ("" if the file does not exist).
func confLoad() {
    emit readFile(confPath())
}

// confGet(conf, key, def): trimmed value for `key`, or `def` if absent.
func confGet(conf, key, def) {
    let n = lineCount(conf)
    let i = 0
    while i < n {
        let line = trim(getLine(conf, i))
        if len(line) > 0 && line[0] != "#" {
            let eq = indexOf(line, "=")
            if eq > 0 {
                let k = trim(substring(line, 0, eq))
                if k == key {
                    let v = substring(line, eq + 1, len(line))
                    let h = indexOf(v, "#")          // strip inline comment
                    if h >= 0 { v = substring(v, 0, h) }
                    emit trim(v)
                }
            }
        }
        i = i + 1
    }
    emit def
}

// confGetInt(conf, key, def): integer value, or `def` (int) if absent/blank.
func confGetInt(conf, key, def) {
    let v = confGet(conf, key, "")
    if v == "" { emit def }
    emit toInt(v)
}
