# kryoterm — Krypton-native terminal

A terminal emulator written in pure **Krypton + KryptScript**, no C, no
C++, no Qt, no GTK, no libX11/libxcb. The window comes from
[`stdlib/x11.k`](https://github.com/t3m3d/krypton/blob/main/stdlib/x11.k)
(the Krypton X11 wire-protocol client) and the binary is a static,
syscall-only ELF — just like every other Krypton program.

**Status: phase 0 (stub).** Spawns a child process via `shellRun()` and
echoes its output to stdout. No window yet, no PTY yet, no escape-code
handling yet. Building blocks lock in over the next few phases.

## Why this exists

`terk` (the sibling project) is a perfectly good Qt6/C++ terminal — but
it pulls in Qt6, cmake, a C++ compiler, and an entire desktop GUI stack
just to draw text in a box. The whole point of Krypton is to escape
that. Once `stdlib/x11.k` ships Phase C (drawing), kryoterm can draw the
same text in the same box with **zero non-Krypton dependencies** at
runtime and only `krypton` at build time. That's the trajectory.

When kryoterm reaches feature parity with terk's "render bytes to a
window" core, terk becomes optional rather than primary.

## Phases

| Phase | What it does | Depends on |
|---|---|---|
| 0 (today) | Spawn child via `shellRun`, echo output | `exec`/`shellRun` (shipped) |
| 1 | Open a window via `x11.k` Phase B, draw a placeholder | `stdlib/x11.k` Phase B (agent-l, in progress) |
| 2 | Render child output as text in window | `stdlib/x11.k` Phase C: `ImageText8` (agent-l, planned) |
| 3 | Real PTY via `forkpty` syscall | new builtin in `elf.k` (agent-l, future) |
| 4 | ANSI escape-code handling, scrollback, themes | pure-Krypton stdlib (agent-w, future) |
| 5 | Wayland transport via `stdlib/wayland.k` | `stdlib/wayland.k` (agent-l, future) |

## Build

```bash
./build_linux.sh           # builds ./kryoterm against $KRYPTON_ROOT/kcc.sh
./build_linux.sh --run     # build then run once
```

Set `KRYPTON_ROOT=/path/to/krypton` if your krypton checkout isn't at
`../krypton`. No gcc / cmake / clang in the build path — kcc handles
everything.

Arch users: `makepkg -si` once the PKGBUILD lands.

## Code layout

- [`run.k`](run.k) — the compiled core. Krypton, not KryptScript. This
  is where the X11 wire calls, PTY syscalls, and render loop will live
  once those phases land.
- [`run.ks`](run.ks) — KryptScript entry. Higher-level glue:
  command-line parsing, config file loading, theme switching. Calls
  into the compiled core.
- `build_linux.sh` — kcc wrapper. The only shell script in the repo.

The split mirrors yubikrypt's convention: the heavy lifting is `.k`,
the user-facing scripting is `.ks`.

## What kryoterm is NOT

- A drop-in replacement for terk **today**. It will be after Phase 2/3.
- A serial console / SSH client / multiplexer. Just a terminal emulator
  speaking VT100-ish to a local child process.
- Going to support every TUI app from day one. ncurses programs need a
  real PTY (Phase 3); shells need ANSI handling (Phase 4). Until then
  it's a pretty echo box.

## License

MIT — see [LICENSE](LICENSE).
