# kryoterm — Krypton-native terminal

A terminal emulator whose **engine is pure Krypton** — no C, no C++, no Qt/GTK.
The shell, the pseudo-terminal, and the ANSI/grid renderer are all native
Krypton (macho backend `svc` syscall builtins + `term.k`). On macOS a thin,
**temporary** Obj-C/Cocoa shim opens the window and forwards keystrokes — the one
thing the Krypton backend can't do yet (no `objc_msgSend` FFI). The shim does
*only* window + draw + keys; everything terminal lives in Krypton.

**Status: working macOS terminal.** Live `/bin/zsh` (sources your `~/.zshrc` —
powerlevel10k, history, aliases), full colour incl. truecolor, scrollback,
selection/copy, find, resize reflow, configurable theme/font/cursor. Typing
`exit` (or any shell EOF) closes the window — the bridge reaps the shell via the
native `waitChild` builtin and shuts down.

```
 keyboard ─▶ Obj-C shim ─(pipe)▶ kryoterm -i ─(pty)▶ /bin/zsh
 window   ◀─ Obj-C shim ◀(frames)─ kryoterm -i ◀──────  (term.k grid)
```

## Run

```bash
./gui.sh          # builds the shim if needed, launches the windowed terminal
./build_app.sh    # assemble kryoterm.app — then double-click in Finder / Spotlight
```

`gui.sh` runs `kryoterm-gui` (the Obj-C shim) against the pure-Krypton
`kryoterm` binary. To rebuild the pieces:

```bash
./build_gui.sh    # clang -framework Cocoa -fobjc-arc  gui_shim.m -o kryoterm-gui
# kryoterm itself is built from run.k with the Krypton macho driver (kcc --native)
```

macOS + Apple Silicon. A [JetBrainsMono Nerd Font](https://www.nerdfonts.com/)
is recommended so powerline/icon glyphs render (configurable).

## Engine (pure Krypton)

- **`term.k`** — incremental ANSI grid driver. Packed-string state (char +
  fg/bg attr planes + cursor + scrollback). Handles CUP/CUU/…/EL/ED (param-aware),
  ESC7/8 + `ESC[s/u` cursor save/restore, deferred wrap (auto-margin), SGR
  256-colour **and** truecolor (`48;2;r;g;b` → nearest xterm-256), multi-byte
  UTF-8 single-column cells, scroll with scrollback capture, OSC 0/2 title,
  find (`gridFind`).
- **`run.k -i`** — interactive bridge. Spawns the shell on a pty (native
  `ptyMaster`/`ptyForkExec`/`fdRead`/`fdWrite`/`fdSetNonblock`/`sleepUs`), feeds
  output through the grid, coalesces settled frames, and emits each as
  `SOH header SOH grid \f`. Reads keystrokes + control markers (resize / scroll /
  clear / find) back on stdin.
- **`pty.k`** — pty wrapper. **`ansi.k`** — standalone `stripAnsi`.

The shim (`gui_shim.m`) is explicitly temporary — delete it once the Krypton
macho backend gains `objc_msgSend`/AppKit FFI.

## Shortcuts

| Key | Action |
|---|---|
| ⌘C / ⌘V / ⌘A | copy selection / bracketed paste / select all |
| ⌘F · ⌘G · ⌘⇧G | find in scrollback · next · prev |
| ⌘K | clear screen + scrollback |
| ⌘N / ⌘Q | new window / quit |
| ⌘+ / ⌘− / ⌘0 | font zoom in / out / reset |
| ⌘↑ / ⌘↓ | scrollback page up / down |
| ⌘Home / ⌘End | scrollback top / back to live |
| scroll wheel | scrollback |
| drag · 2-click · 3-click | select · word · line |
| ⌘-click · middle-click | open URL · paste |

## Config

`~/.config/kryoterm/config` (auto-created, hot-reloads on window focus):

```ini
titlebar_light   = #2b2b2b      # dark grey in light mode, …
titlebar_dark    = #000000      # … black in dark mode (follows system appearance)
background_light = #2b2b2b
background_dark  = #000000
cursor_blink_ms  = 530          # 0 = steady
cursor_color     = #d8dad4
cursor_style     = bar          # bar | block | underline
font_family      = JetBrainsMono Nerd Font Mono
font_size        = 13
opacity          = 1.0          # 0.2–1.0, translucent bg (text stays opaque)
padding          = 6
line_spacing     = 0            # extra px between rows
bell             = visual       # visual | audible | off
copy_on_select   = false        # auto-copy selection; middle-click pastes
scrollback_lines = 2000
```

`⌘A` selects all · `⌘-click` opens underlined URLs · ⇧PageUp/Down also scrolls.

## Why this exists

Krypton's whole point is escaping the C/C++/Qt stack — static, syscall-only
binaries with zero non-Krypton runtime deps. kryoterm proves a *terminal* can be
built that way: the engine already is. The only non-Krypton code is the macOS
window shim, kept deliberately small and marked for deletion once AppKit FFI
lands in the backend. (A Linux window path — `stdlib/x11.k`/Wayland — is the
other route to closing that gap.)

## License

MIT — see [LICENSE](LICENSE).
