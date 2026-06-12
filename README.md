# stem — Krypton-native terminal

A terminal emulator that is **pure Krypton** — no C, no C++, no Qt/GTK, **no
Obj-C source**. The shell, the pseudo-terminal, the ANSI/grid renderer, AND the
macOS window/drawing/keyboard are all native Krypton: the engine on the macho
backend `svc` syscall builtins (`term.k`), and the Cocoa GUI on the **objk**
Objective-C FFI (`stdlib/cocoa.k` — `NSWindow`, custom `NSView` `drawRect:`,
`keyDown:` → pty, `NSTimer` pump). The shipped app links only `libobjc` +
`Foundation` + `AppKit` — verify: `otool -L`.

**Status: working macOS terminal.** Live `/bin/zsh` (sources your `~/.zshrc` —
powerlevel10k, history, aliases), full colour incl. truecolor, scrollback,
selection/copy, find, resize reflow, configurable theme/font/cursor. Runs full
TUIs — **mouse reporting** (X10/SGR-1006, wheel scrolls in alt-screen),
**alternate screen** (1049/1047/47), **cursor show/hide** (DECSET 25) +
**shape** (DECSCUSR), **bracketed paste** (2004) and **focus reporting** (1004) —
so vim, htop, less, tmux work. **Multi-pane**: splits (⌘D / File menu), native
macOS tabs (⌘T), multiple windows (⌘N) — each pane its own shell. Typing `exit`
(or any shell EOF) closes that pane; the bridge reaps the shell via the native
`waitChild` builtin and shuts down.

```
 keyboard ─▶ stem.ks keyDown: ─(pty)▶ /bin/zsh
 window   ◀─ stem.ks drawRect: ◀───── term.k grid ◀── pty  (all pure Krypton / objk)
```

## Install (macOS, Apple Silicon)

```bash
brew tap t3m3d/krypton          # once
brew install stem           # the `stem` command -> run it to open a window
brew install --cask stem    # OR a clickable stem.app in /Applications
```

The cask app is ad-hoc signed (not notarized) — first launch, right-click → Open
(or `xattr -dr com.apple.quarantine /Applications/stem.app`).

Self-contained — no krypton runtime dependency. A
[JetBrainsMono Nerd Font](https://www.nerdfonts.com/) is recommended for the
powerline/icon glyphs (configurable in `~/.config/stem/config`).

## Build from source

The build scripts are KryptScript (`.ks`, run with `kcc -r`), not shell.

```bash
kcc -r build_objk.ks   # → dist/stem.app (pure Krypton, no Obj-C source)
open dist/stem.app
```

`build_objk.ks` compiles `stem.ks` (window + custom `NSView` `drawRect:` grid +
`keyDown:` → pty + `NSTimer` pump) straight to a `.app` on the objk FFI; the
result links only `libobjc`/`Foundation`/`AppKit` (`otool -L` to confirm). Build
the CLI engine alone with `kcc -r build.ks` (run.ks → `./stem`); the icon with
`kcc -r make_icon.ks`. Linux/Windows: `build_linux.ks` / `build_windows.ks`.

objk shipped in **Krypton 2.4.0**, so a released `kcc` builds it — no dev
checkout needed. (`build_objk.ks` honors `KRYPTON_ROOT` for a dev tree if you
have one; otherwise it uses the installed toolchain.)

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
- **`stem.ks`** — the pure-Krypton Cocoa GUI on the **objk** FFI: `NSWindow`,
  custom `NSView` `drawRect:` (renders the `term.k` grid), `keyDown:` → pty,
  `NSTimer`/event-pump read loop, menus. No Obj-C source; see *Build from source*.

## Shortcuts

| Key | Action |
|---|---|
| ⌘C / ⌘V / ⌘A | copy selection / bracketed paste / select all |
| ⌘F · ⌘G · ⌘⇧G | find in scrollback · next · prev |
| ⌘K | clear screen + scrollback |
| ⌘N / ⌘T | new window / new tab |
| ⌘D / ⌘⇧D | split right / split down (File menu: also left / up) |
| ⌘W / ⌘⇧W / ⌘⌥W | close pane / close window / close all |
| ⌘Q | quit |
| ⌘+ / ⌘− / ⌘0 | font zoom in / out / reset |
| ⌘↑ / ⌘↓ | scrollback page up / down |
| ⌘Home / ⌘End | scrollback top / back to live |
| scroll wheel | scrollback |
| drag · 2-click · 3-click | select · word · line |
| ⌘-click · middle-click | open URL · paste |

## Config

`~/.config/stem/config` (auto-created, hot-reloads on window focus):

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
binaries with zero non-Krypton runtime deps. stem proves a *terminal* can be
built that way: the engine already is. The only non-Krypton code is the macOS
window shim, kept deliberately small and marked for deletion once AppKit FFI
lands in the backend. (A Linux window path — `stdlib/x11.k`/Wayland — is the
other route to closing that gap.)

## License

MIT — see [LICENSE](LICENSE).
